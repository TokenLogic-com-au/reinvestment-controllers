# ReinvestmentController

Reinvestment controller for Aave v4. Sweeps idle USDC out of the Hub, deposits it into
Circle's Gateway, and reclaims it on demand.

Deployed behind a `TransparentUpgradeableProxy`. Protocol addresses are immutable on the
implementation; limits and roles are set in `initialize`.

## Flow

- `invest` — sweeps from the Hub and deposits into the Gateway wallet
- `divest` — mints against a Circle attestation and reclaims to the Hub
- `initiateWithdrawal` / `withdraw` — on-chain exit path, subject to the Gateway's delay
- `isValidSignature` — ERC-1271, authorises burn intents signed by a `KEEPER_ROLE` holder

How much can be invested is bounded by the absolute exposure cap, the exposure cap in BPS of
supplied assets, and a liquid buffer of Hub liquidity that must stay idle. Set the absolute exposure
cap to zero to sunset.

## Fee accounting

The Gateway debits `amount + fee` when Circle burns, but mints only `amount`. Left alone,
each divest leaves the Hub's `swept` figure overstating the balance actually recoverable at
the Gateway. That is not just an unrecoverable balance: `swept` is counted at face value in
the Hub's `totalAddedAssets`, so the gap prices into supplier shares as phantom assets, and
the Hub has no way to write it down — `reportDeficit` is spoke-only and untied to `swept`.

So `divest` pre-pays: the caller transfers `maxFee` in, and the controller reclaims
`amount + maxFee`. The pre-payment is `maxFee` regardless of what Circle actually charges,
because a lower fee is not knowable on-chain — Circle attests before it burns, and neither the
attestation nor the transfer spec carries a fee. Circle charges a flat fee equal to `maxFee`
today, so the two match exactly and nothing is left behind. Were it ever to charge less, the
difference would stay in the Gateway, leaving it holding more than `swept` rather than less —
the opposite of the phantom-asset case above, and the safe direction. `initiateWithdrawal` caps
its withdrawal at `swept`, so neither that residue nor a third-party `depositFor` donation can
block the exit.

`setMaxFee` only works while paused. `divest` pre-pays the cap in force when it runs, but
Circle charges against the cap in force when the burn intent was signed, and nothing on-chain
links the two. Pausing stops new validations and stops `divest` consuming attestations while
the cap changes, but it does not cancel intents already attested (see Trust assumptions). To
lower the cap, let outstanding intents settle through `divest` first, then pause and lower.
Raising it needs no draining, since it only over-funds the Hub.

The attestation names **the controller** as `destinationRecipient`, not the Hub. Minting
straight to the Hub would remove the transfer, but `Hub.reclaim` only checks that the Hub's
aggregate balance covers `liquidity + amount` — a floor any USDC sitting there satisfies,
whatever its origin. Routing through the controller keeps the chain self-verifying: it
receives exactly `amount`, transfers exactly `amount + maxFee`, reclaims the same, each step
proven by its own balance rather than by a balance coincidence at the Hub. It also keeps
`_validateTransferSpec` pinning depositor, recipient, signer and destination caller all to
`self`, which is what makes the spec check easy to audit.

## Dust

Because of the fee accounting mentioned above, dust is left at the Gateway.
The accounting matches holdings exactly while Circle's fee matches `maxFee`.
Two things can push the Gateway balance above that: Circle charging less than the
cap, or a third party calling `depositFor` on the controller. Either way
the excess is real USDC the Hub has never counted, and no existing path can reach it.
`divest` and `isValidSignature` both bound their intents by `swept`, so a burn intent
for the surplus can never be attested, and `initiateWithdrawal` caps at `swept` by
design. Once the Hub is fully divested and `swept` is zero, every exit is closed and
the residue is stranded.

`initiateDustWithdrawal` and `claimDust` reopen it through the on-chain exit, which
needs no attestation and so is untouched by the `swept` bound in `isValidSignature`.
It only runs once `swept` is zero, when the Hub has no claim left on the Gateway, so it
queues the whole available balance and principal is out of reach by construction. Both
functions require the controller to be paused, which keeps `swept` at zero for the
duration of the Gateway's withdrawal delay. While `swept` is above zero, dust stays in
the Gateway: it over-backs the Hub's claim, which is the safe direction, and can be
collected after a full divest.

The dust is forwarded to a recipient, not reclaimed to the Hub. `reclaim` is capped at
`swept` and only trades the Hub's claim for cash — it moves `swept` into `liquidity`,
leaving `totalAddedAssets` unchanged — so it can never reach the surplus and would
immediately recreate it. Residue that was never principal does not re-enter Hub
accounting. This way treasury can reclaim the excess fees it paid if it is the recipient.

Requiring `swept` to be zero is what makes the timing of burns irrelevant. `divest`
lowers `swept` as soon as it mints, while the Gateway balance drops minutes later when
Circle burns, so a burn may still be pending when the dust withdrawal is queued. The
Gateway debits a burn from the available balance first and takes the rest from the
withdrawing balance, so the pending burn takes its funds from the queued amount and what
is left is exactly the dust, including anything donated in the meantime. With `swept`
above zero, the same burn would first drain the balance backing `swept`. `claimDust` could
then no longer pay out without leaving the Hub's claim unbacked, and if the queue held
any real dust, `withdraw` would try to reclaim more than `swept` and revert, leaving the
controller paused with no way to finish the withdrawal.

`claimDust` still requires `available >= swept` after the Gateway pays out, so a payout
can never leave the Hub's claim unbacked. Circle burns minutes after a mint, well within
the Gateway's withdrawal delay. Were a burn ever to land after the claim, it would come up
short at the Gateway rather than at the Hub, since `swept` is zero.

## Trust assumptions

The Gateway is Circle's. We depend on them for:

- **Attestations.** Minting requires a payload signed by an attestation signer. The signer
  set is controlled by the minter's owner, and attestations are obtained off-chain via
  Circle's API. Transaction size limit is imposed by the API.
- **Burns.** Circle burns an intent only after observing its mint in a finalized block, so a
  burn always follows a `divest`. The controller cannot observe or enforce this ordering.
- **Batch adjustments.** A signer registered by the wallet's owner can debit the controller's
  Gateway balance through `submitBatch`, with no signature from us and no burn intent. The
  controller never registers such a signer and cannot decline one, since the debit path checks
  only that the signer is registered. Batches must net to zero across depositors, so balance
  moves rather than disappears, and debits can reach funds pending withdrawal.
- **Withdrawal delay.** The on-chain exit delay is the wallet's `withdrawalDelay`, owner
  controlled. The controller does not enforce its own.
- **Pausing and denylisting.** Circle can pause either contract, denylist the controller,
  or drop USDC support. Any of these halts `invest`, `divest` or `withdraw`.
- **Upgradeability.** Both the wallet and the minter are upgradeable by Circle. This contract is
  upgradeable in case it needs to be updated post Circle upgrade.

On the Aave side, only governance can attach or detach the controller, via
`Hub.updateAssetConfig`. It cannot be detached while the asset still has a swept balance.

The keeper is trusted not to manipulate the Hub's balances to get around the relative limits.
`getInvestableAmount` reads supplied assets and idle liquidity at call time, so a keeper that
temporarily inflates them, for example by supplying flash-borrowed USDC in the same transaction,
can invest beyond what `exposureCapBps` and `liquidBufferBps` would otherwise allow. Those two
are policy limits, meant to stop an honest keeper from stranding liquidity, not a defense against
the keeper itself. `exposureCapAbs` does not depend on any balance that can move within a
transaction, so it is the hard bound on how much can ever sit at the Gateway, and it is the
parameter to set conservatively.

Note that `isValidSignature` is a view function and cannot record what it has signed for.
Multiple burn intents are each validated against the same balance; the wallet's own
accounting is what prevents over-burning.

A pause or a `KEEPER_ROLE` revocation cannot invalidate a signature Circle's TEE has already
issued. `isValidSignature` is not called again at burn time: `gatewayBurn` accepts a registered
TEE signer's signature as proof the TEE validated the intent against a quorum of RPCs. RPC lag
also means the TEE may briefly approve against pre-pause state. This is inherent to Gateway's
ERC-1271 support. Because Circle burns only after a finalized mint, and every mint goes through
`divest`, a pause also holds back the burn of any intent not yet minted; it resumes once
unpaused. A burn whose mint already finalized still lands, which settles accounting `divest`
already recorded. During an on-chain exit, `initiateWithdrawal` caps at `swept`, which leaves
exactly that pending burn in the available balance. Intents signed
before a `setMaxFee` change stay mintable after unpause, which is why the cap must be drained
before it is lowered.

## Usage

```shell
forge build
forge test
```

The gas snapshots in `tests/gas` call `vm.snapshotGasLastFrame`, which needs a recent Foundry.
If it reports an unknown cheatcode, update with `foundryup`.

Fork tests run against mainnet and need `RPC_MAINNET` set in `.env`.

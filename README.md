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
The amount withdrawn is `available - swept`, never more, so principal is out of reach
by construction: the pair only ever moves what sits above the Hub's claim, the same
line `initiateWithdrawal` refuses to cross from the other side. Both require the
controller to be paused, which freezes `swept` for the duration of the Gateway's
withdrawal delay.

The dust is forwarded to a recipient, not reclaimed to the Hub. `reclaim` is capped at
`swept` and only trades the Hub's claim for cash — it moves `swept` into `liquidity`,
leaving `totalAddedAssets` unchanged — so it can never reach the surplus and would
immediately recreate it. Residue that was never principal does not re-enter Hub
accounting. This way treasury can reclaim the excess fees it paid if it is the recipient.

`available - swept` only measures surplus once every burn has settled. `divest` lowers
`swept` as soon as it mints, while the Gateway balance drops minutes later when Circle
burns, so between those two points the difference is money already owed rather than
dust. `initiateDustWithdrawal` cannot tell the two apart and queues the pending burn's
amount along with the dust.

`claimDust` is what makes that safe. When the burn lands during the withdrawal delay, it
drains the available balance backing `swept`, and may spill into the queued amount if it
is larger than what is available. Either way, after the Gateway pays out, `available` is
below `swept`, which shows the queue holds money owed to Circle, possibly for further
burns still pending. `claimDust` then pays nothing out and finalizes the withdrawal as
`withdraw` does. Otherwise it forwards the whole queued amount. With `swept` at zero, a
burn can take the whole queue, leaving nothing to complete; `unpause` and
`initiateWithdrawal` then discard the dust withdrawal, so `claimDust` cannot later pay
out a principal withdrawal as dust.

`withdraw` returns withdrawn funds to the Hub capped at `swept`, since the Hub can take
back no more, and deposits any excess back into the Gateway. A principal withdrawal
never exceeds `swept`, so the cap only binds when a burn spills into a queued dust
withdrawal. With `swept` at zero, nothing is reclaimed and the whole withdrawal goes back.
The re-deposited excess covers any burn still pending against it, even after
the controller invests again. What is left over-backs `swept` as dust, and a later
`initiateDustWithdrawal` collects it once no burn lands during its delay.

This catches a burn only once it has landed, and only while its debit is still visible
in `available`. It therefore relies on every burn landing before the claim, the one
assumption dust recovery depends on; see _Burn latency_ under Trust assumptions.

## Trust assumptions

The Gateway is Circle's. We depend on them for:

- **Attestations.** Minting requires a payload signed by an attestation signer. The signer
  set is controlled by the minter's owner, and attestations are obtained off-chain via
  Circle's API. Transaction size limit is imposed by the API.
- **Burns.** Circle burns an intent only after observing its mint in a finalized block, so a
  burn always follows a `divest`. The controller cannot observe or enforce this ordering.
- **Burn latency.** Dust recovery relies on one condition: every burn lands before the
  dust claim, which runs no earlier than the withdrawal delay after the dust withdrawal is
  queued. Burns landing after the claim are out of scope: the controller does not guard
  against them, and recovering from one is a manual treasury action.
  A burn landing after the claim is the only way a claim can pay out funds that are
  not dust. Every burn that lands earlier is caught, and the donation case below still needs
  another burn to be late.
  `claimDust` can only tell that a queued dust withdrawal holds money owed to Circle from
  `available` falling below `swept`, which takes a burn that has already landed. A burn
  still pending when the claim runs leaves no such trace, since the state then reads the
  same as one holding only real dust. With several burns pending, one that lands during
  the delay exposes the rest, but a third-party `depositFor` during the delay can offset
  its debit and hide them again, since `available` cannot tell a donation from the balance
  the burn took. Nor does a landed burn expose the rest once the divests have taken `swept`
  to zero, as `available` cannot fall below it. Either way the claim pays the pending
  burn's funds to the recipient, and that burn leaves `swept` unbacked by its amount once
  it lands. With `swept` at zero the Hub is unaffected, and the burn lands short instead,
  against an empty balance. A donor gains nothing:
  hiding a landed burn costs at least its amount, for a shortfall that still needs another
  burn to be late. The recipient holds the admin role, so treasury can restore the balance
  with `depositFor`. Circle settles burns minutes after a mint, against a delay of days,
  but the delay is owner controlled (see _Withdrawal delay_), and shortening it narrows
  that margin.
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

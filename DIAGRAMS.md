# ReinvestmentController architecture

ReinvestmentController moves idle USDC from an Aave Hub into Circle Gateway and returns liquidity to the Hub through same-chain mint-and-burn transfers. The controller owns the Gateway deposit; keepers execute operations and sign transfer authorizations on its behalf.

The diagrams describe successful investment and divestment using Circle's documented enclave-based ERC-1271 authorization, followed by the paused on-chain exit paths: principal withdrawal and dust recovery. Deployment requires a Gateway Wallet and backend that support this settlement path. Gateway versions using direct ERC-1271 callbacks have different authorization requirements, described under [Settlement compatibility](#settlement-compatibility).

## Components

| Component              | Responsibility                                                                                             |
| ---------------------- | ---------------------------------------------------------------------------------------------------------- |
| Aave Hub               | Holds protocol liquidity and tracks `swept`, the assets allocated to the controller and not yet reclaimed. |
| ReinvestmentController | Enforces investment limits, validates keeper authorizations, and moves funds between the Hub and Gateway.  |
| Keeper EOA             | Calls `invest()` and `divest()`, signs burn intents, and funds the configured divestment fee contribution. |
| Pauser                 | Pauses the controller, which halts investment, divestment, and burn-intent validation.                     |
| Admin                  | Unpauses the controller and runs the paused withdrawal and dust-recovery paths.                            |
| Gateway Wallet         | Holds the controller's deposited USDC and executes source-side debits, fees, and burns.                    |
| Gateway Minter         | Verifies Circle attestations and mints USDC to the controller.                                             |
| Circle backend         | Tracks finalized deposits and reserved balances, issues attestations, and submits settlement transactions. |
| Validation enclave     | Validates ERC-1271 authorization using an independent RPC quorum and signs burn intents for settlement.    |

## 1. Investment

`invest(amount)` transfers USDC from the Hub to the Gateway Wallet in one atomic transaction. Circle credits its off-chain balance ledger after the deposit reaches finality.

```mermaid
sequenceDiagram
    participant K as Keeper EOA
    participant C as ReinvestmentController
    participant H as Aave Hub
    participant U as USDC
    participant W as Gateway Wallet
    participant B as Circle backend

    Note over K,W: One on-chain invest transaction
    K->>C: invest(amount)
    C->>C: Check keeper role, pause, delay and investment limits
    C->>H: sweep(assetId, amount)
    H->>H: Decrease liquidity and increase swept
    H->>U: transfer(controller, amount)
    U-->>C: Controller receives amount
    C->>U: approve(Gateway Wallet, amount)
    C->>W: deposit(USDC, amount)
    W->>U: transferFrom(controller, wallet, amount)
    W->>W: Credit controller's available balance
    W-->>C: Deposit completes
    C-->>K: invest completes
    Note over W,B: After deposit finality
    W-->>B: Backend observes finalized deposit event
    B->>B: Credit controller's off-chain spendable balance
```

The deposit is authorized by the keeper's transaction and the controller's token allowance. It does not require an attestation.

## 2. Transfer authorization

Before divestment, the keeper requests a mint attestation from Circle. It signs a burn intent using EIP-712 and includes the encoded intent alongside its signature in the controller's custom ERC-1271 signature data. The enclave validates this authorization against recent blockchain state and signs the burn intent for subsequent settlement.

```mermaid
sequenceDiagram
    participant K as Keeper EOA
    participant B as Circle backend / API
    participant E as Validation enclave
    participant R as Independent RPC providers
    participant C as ReinvestmentController

    K->>K: Create burn intent and sign its EIP-712 digest
    Note over K: signatureData = abi.encode(keeperSignature, burnIntentPayload)
    K->>B: POST /v1/transfer: burnIntent, signature=signatureData, contractSigner=true
    B->>B: Check transfer and available balance including fee
    B->>E: Request contract-signature validation
    E->>R: Simulate at a recent target block
    R->>C: eth_call: isValidSignature(digest, signatureData)
    C->>C: Recompute digest and check keeper role, pause and intent constraints
    C-->>R: ERC-1271 valid-signature result
    R-->>E: RPC quorum agrees on validity
    E->>E: Sign burn intent with registered enclave key
    E-->>B: Enclave signature for later burn settlement
    B->>B: Reserve balance and issue signed mint attestation
    B-->>K: Encoded attestation + Circle attestation signature
```

ERC-1271 validation is a read-only RPC simulation. Circle documents a quorum of at least two of three independent RPC providers. The diagram shows the backend's logical responsibilities, rather than its internal scheduling.

The controller requires the same source and destination chain. The transfer specification's depositor, source signer, destination recipient, and permitted destination caller must all be the controller address.

### Authorization messages

| Message                | Contents                                                                                                              | Purpose                                                   |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------- |
| Transfer specification | Source and destination domains, contracts, tokens, depositor, recipient, signer, caller, amount, salt, and hook data. | Identifies the transfer shared by its mint and burn.      |
| Burn intent            | Transfer specification, source-chain expiry block, and maximum fee.                                                   | Authorizes debiting the Gateway deposit.                  |
| Attestation            | Transfer specification and destination-chain expiry block.                                                            | Authorizes minting the specified amount to the recipient. |

Signatures are supplied separately from these message structures.

| Signature                  | Signer                        | Verification                                                                                         |
| -------------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------- |
| Keeper signature           | Keeper EOA                    | The controller checks the signature, keeper role, and intent constraints during ERC-1271 validation. |
| Attestation signature      | Circle attestation signer     | The Gateway Minter checks mint authorization. This signature is passed to `divest()`.                |
| Enclave signature          | Registered validation enclave | The Gateway Wallet checks burn authorization without repeating the controller callback.              |
| Outer burn-batch signature | Circle burn operator          | The Gateway Wallet checks authorization for the submitted batch of intents, signatures, and fees.    |

## 3. Divestment

`divest()` consumes the attestation, receives newly minted USDC, and returns liquidity to the Hub in one atomic transaction. Let `A` be the mint amount and `Fcfg` the controller's configured `maxFee`. The keeper supplies `Fcfg` from its own USDC balance and must grant the controller sufficient allowance beforehand.

```mermaid
sequenceDiagram
    participant K as Keeper EOA
    participant C as ReinvestmentController
    participant M as Gateway Minter
    participant U as USDC / mint authority
    participant H as Aave Hub

    Note over K,H: One atomic divest transaction
    K->>C: divest(A, attestationPayload, CircleSignature)
    C->>C: Check keeper role, pause and A + Fcfg <= swept
    C->>C: Validate attestation transfer spec and amount
    C->>M: gatewayMint(attestationPayload, CircleSignature)
    M->>M: Verify Circle signer, expiry, destination, caller, token and replay
    M->>M: Check pause / denylist and mark transfer used
    M->>U: mint(controller, A)
    U-->>C: Controller receives A USDC
    M-->>C: Emit AttestationUsed and return from mint
    C->>U: transferFrom(keeper, controller, Fcfg)
    U-->>C: Controller receives keeper's fee contribution
    C->>U: transfer(Hub, A + Fcfg)
    U-->>H: Hub receives A + Fcfg USDC
    C->>H: reclaim(assetId, A + Fcfg)
    H->>H: Increase liquidity and decrease swept by A + Fcfg
    C-->>K: divest completes
```

The controller returns and reclaims `A + Fcfg`. A failure at any step reverts the entire transaction, including the mint and its event. The source-side Gateway deposit remains unchanged until settlement.

## 4. Burn settlement

After observing the finalized `AttestationUsed` event, Circle submits a separate burn transaction. The Gateway Wallet validates the enclave's signature, debits the controller's deposit, pays the fee, and burns the principal. `Fact` is the actual fee, capped by the burn intent's signed maximum `Fmax`.

```mermaid
sequenceDiagram
    participant M as Gateway Minter
    participant B as Circle backend
    participant W as Gateway Wallet
    participant U as USDC
    participant F as Fee recipient

    Note over M,B: After the divest transaction reaches finality
    M-->>B: Backend observes finalized AttestationUsed
    Note over B,F: Separate on-chain burn transaction
    B->>W: gatewayBurn(batchPayload, operatorSignature)
    Note over B,W: Batch contains burn intent, enclave signature and actual fee
    W->>W: Verify outer operator signature
    W->>W: Verify per-intent signer is a registered enclave
    Note over W: No controller.isValidSignature callback on this path
    W->>W: Validate intent, burn deadline, Fact <= Fmax and replay
    W->>W: Mark transfer used and debit controller balance by A + Fact
    W->>U: transfer(feeRecipient, Fact)
    U-->>F: Fee recipient receives Fact
    W->>U: burn(A)
    W-->>B: Burn settlement completes
```

The diagram assumes sufficient deposited funds to cover the principal and fee. Minting and burning are separate transactions coordinated by Circle's backend.

## 5. On-chain withdrawal

`initiateWithdrawal()` and `withdraw()` return principal to the Hub through the Gateway Wallet's own withdrawal mechanism. This path needs no attestation, burn intent, or Circle backend involvement, and is the exit when divestment is unavailable. Withdrawal is capped at `swept`, so a Gateway balance above the Hub's claim never re-enters Hub accounting through it.

```mermaid
sequenceDiagram
    participant P as Pauser
    participant A as Admin
    participant C as ReinvestmentController
    participant W as Gateway Wallet
    participant U as USDC
    participant H as Aave Hub

    P->>C: pause()
    A->>C: initiateWithdrawal()
    C->>C: Check admin role, paused and no pending withdrawal
    C->>C: amount = min(available, swept)
    C->>W: initiateWithdrawal(USDC, amount)
    W->>W: Move amount from available to withdrawing balance
    Note over W: Gateway withdrawal delay (blocks)
    A->>C: withdraw()
    C->>W: withdraw(USDC)
    W->>U: transfer(controller, withdrawing balance)
    U-->>C: Controller receives amount
    C->>C: reclaimAmount = min(amount, swept)
    opt reclaimAmount > 0
        C->>U: transfer(Hub, reclaimAmount)
        C->>H: reclaim(assetId, reclaimAmount)
        H->>H: Increase liquidity and decrease swept by reclaimAmount
    end
    opt amount > reclaimAmount
        C->>W: deposit(USDC, amount - reclaimAmount)
    end
    A->>C: unpause()
    C->>C: Check no withdrawal in process
```

`withdraw()` does not require the controller to be paused, so a pending withdrawal can always complete, and `unpause()` is refused until it does. A principal withdrawal never exceeds `swept`, so the `min` only binds when `withdraw()` finalizes a dust withdrawal that a burn spilled into. The excess is deposited back into the Gateway, where it covers any burn still pending against it or is left as dust. Because `divest()` requires `A + Fcfg <= swept`, the last `Fcfg` of `swept` cannot be divested and leaves through this path.

## 6. Dust recovery

Dust is Gateway balance above `swept`. It accumulates when Circle charges less than `Fcfg` or when a third party calls `depositFor` on the controller. Neither divestment nor on-chain withdrawal can reach it, since both are bounded by `swept`. `initiateDustWithdrawal()` and `claimDust(recipient)` withdraw it and forward it to an admin-held recipient, rather than reclaiming it to the Hub.

```mermaid
sequenceDiagram
    participant P as Pauser
    participant A as Admin
    participant C as ReinvestmentController
    participant W as Gateway Wallet
    participant U as USDC
    participant R as Recipient (admin)
    participant H as Aave Hub

    P->>C: pause()
    A->>C: initiateDustWithdrawal()
    C->>C: Check admin role, paused and no pending withdrawal
    C->>C: dust = available - swept, require dust > 0
    C->>C: pendingDust = dust
    C->>W: initiateWithdrawal(USDC, dust)
    Note over W: Gateway withdrawal delay (blocks)
    A->>C: claimDust(recipient)
    C->>C: Check recipient holds admin role and pendingDust > 0
    C->>C: pendingDust = 0
    C->>W: withdraw(USDC)
    W->>U: transfer(controller, withdrawing balance)
    alt available < swept
        C->>C: reclaimAmount = min(withdrawing balance, swept)
        C->>U: transfer(Hub, reclaimAmount)
        C->>H: reclaim(assetId, reclaimAmount)
        opt withdrawing balance > reclaimAmount
            C->>W: deposit(USDC, withdrawing balance - reclaimAmount)
        end
    else
        C->>U: transfer(recipient, withdrawing balance)
        U-->>R: Recipient receives dust
    end
    A->>C: unpause()
```

`available - swept` measures dust only after every burn has settled. `divest()` lowers `swept` at mint, but the Gateway balance drops only when Circle later burns, so between the two the difference is owed to a pending burn. If that burn lands during the withdrawal delay, it drains the available balance first and may spill into the queued amount. `available` then sits below `swept`, which shows the queue holds money owed to Circle, possibly for further burns still pending. `claimDust()` pays nothing out in that case and finalizes the withdrawal as `withdraw()` does. The real dust is left over-backing `swept`, and a later `initiateDustWithdrawal()` collects it. This relies on every burn landing within the withdrawal delay. A burn still pending at the claim cannot be seen on-chain, and a third-party donation during the delay can offset the debit of another burn that landed, which would otherwise expose it. A landed burn exposes nothing either once `swept` is zero, as `available` cannot fall below it. Either way the claim pays the pending burn's funds out (see _Burn latency_ in the README).

## Fee accounting

| Value  | Meaning                                                                                                        |
| ------ | -------------------------------------------------------------------------------------------------------------- |
| `A`    | USDC minted to the controller. The Gateway fee is not subtracted from this amount.                             |
| `Fcfg` | Controller's configured `maxFee`, pulled from the keeper during divest.                                        |
| `Fmax` | Maximum fee authorized in the signed burn intent. Controller checks `Fmax <= Fcfg` when validating the intent. |
| `Fact` | Fee supplied during burn settlement. Gateway checks `Fact <= Fmax`.                                            |

For example, with **100 USDC deposited**, `A = 99` and all three fee values equal to `1`:

- Divest mints **99**, pulls **1** from the keeper, and returns/reclaims **100** at the Hub.
- Later settlement debits **100** from the Gateway balance: **99 burned**, **1 paid as fee**.

If Circle instead charges `Fact = 0.4`, settlement debits only **99.4**, while the Hub has already reclaimed **100**. The remaining **0.6** stays in the Gateway above `swept`. The Hub's claim remains fully backed, and the surplus is recoverable only through [dust recovery](#6-dust-recovery).

## Transaction and trust boundaries

- Investment and divestment each execute atomically on-chain. Attestation issuance and burn submission are separate backend operations.
- The Minter relies on Circle's attestation signature for authorization; it does not verify the source deposit balance or completion of the burn.
- Enclave-based settlement relies on the validation service's request-time ERC-1271 check, RPC quorum, and registered signing key. Subsequent controller state changes do not trigger another ERC-1271 check on this path.
- Gateway's contract configuration, token support, pause controls, and upgrades remain external dependencies of the controller.

## Settlement compatibility

Gateway supports distinct contract-authorization paths. Their signature formats and validation timing must match the integration's backend configuration.

| Path                        | Burn-time behavior                                                                                   | Controller requirement                                                 |
| --------------------------- | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Enclave authorization       | Accepts a registered enclave's signature over the burn intent, without calling the controller again. | Authorization must pass the validation service's request-time check.   |
| Direct allowlisted ERC-1271 | Calls the controller with the original custom signature data during the burn.                        | Authorization must remain valid after divestment and until settlement. |

The repository's pinned Gateway implementation recognizes enclave signatures before falling back to the direct callback path. Confirm the deployed implementation and backend path when configuring an integration or its tests.

The controller's validation reads mutable state, including `swept`. Direct callback settlement can therefore reject a previously accepted intent after `divest()` reduces `swept`. Enclave-based settlement avoids that repeated check.

## Sources

- [Controller invest, divest, withdrawal and dust recovery](src/ReinvestmentController.sol)
- [Fee accounting and dust rationale](README.md#dust)
- [Pinned Gateway enclave and direct signature-validation paths](lib/evm-gateway-contracts/src/modules/wallet/Burns.sol)
- [Circle: Gateway system inputs and finality](https://developers.circle.com/gateway/references/technical-guide#inputs)
- [Circle: ERC-1271 validation and enclave-based burn settlement](https://developers.circle.com/gateway/references/erc-1271#how-erc-1271-validation-works)
- [Current upstream Gateway: enclave signature path before direct ERC-1271 fallback](https://github.com/circlefin/evm-gateway-contracts/blob/master/src/modules/wallet/Burns.sol#L316)

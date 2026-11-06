// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';
import {IGatewayMinter} from './IGatewayMinter.sol';
import {IGatewayWallet} from './IGatewayWallet.sol';

interface IReinvestmentController is IERC1271, IAccessControl {
  /// @dev Burn intent exceeds the invested amount
  error BurnIntentExceedsBalance();

  /// @dev Withdrawals are only allowed on the same network as invested
  error CrossChainTransferNotAllowed();

  /// @dev Provided hash does not match the calculated hash
  error HashMismatch();

  /// @dev Invalid amount provided
  error InvalidAmount();

  /// @dev Payload must contain exactly one burn intent or attestation
  error InvalidElementCount();

  /// @dev Invalid depositor provided in transfer specification
  error InvalidDepositor();

  /// @dev Invalid destination caller provided in transfer specification
  error InvalidDestinationCaller();

  /// @dev Invalid destination contract provided in transfer specification
  error InvalidDestinationContract();

  /// @dev Invalid destination token provided in transfer specification
  error InvalidDestinationToken();

  /// @dev Transfer specification domain does not match the Gateway domain of this chain
  error InvalidDomain();

  /// @dev Gateway wallet and minter are the same contract, or are not configured for USDC
  error InvalidGatewayConfiguration();

  /// @dev Transfer specification carries hook data, which is not supported
  error InvalidHookData();

  /// @dev Invalid mint amount provided in attestation
  error InvalidMintAmount();

  /// @dev Invalid recipient provided in transfer specification, or a {claimDust} recipient
  /// without DEFAULT_ADMIN_ROLE
  error InvalidRecipient();

  /// @dev Signer does not have KEEPER_ROLE to sign transaction
  error InvalidSignature();

  /// @dev Invalid signer provided in transfer specification
  error InvalidSigner();

  /// @dev Invalid source contract provided in transfer specification
  error InvalidSourceContract();

  /// @dev Invalid source token provided in transfer specification
  error InvalidSourceToken();

  /// @dev Amount exceeds the invested amount
  error InsufficientLiquidity();

  /// @dev Provided address cannot be the zero-address
  error InvalidZeroAddress();

  /// @dev Minimum delay between invests has not elapsed
  error InvestMinDelayNotElapsed();

  /// @dev Fee in the burn intent exceeds the maximum allowed fee
  error MaxFeeExceeded();

  /// @dev Amount to be deposited cannot exceed the configured exposure caps
  error ExposureCapExceeded();

  /// @notice Thrown when there is no Gateway balance in excess of the swept amount
  error NoDust();

  /// @dev No dust withdrawal is pending; the queued withdrawal, if any, is principal
  error NoDustWithdrawalInProcess();

  /// @dev No pending on-chain withdrawal
  error NoWithdrawalInProcess();

  /// @dev An existing withdrawal is already in process
  error WithdrawalInProcess();

  /// @dev Emitted when dust is recovered from Gateway
  /// @param recipient Address receiving the dust
  /// @param amount The amount of dust transferred
  event ClaimedDust(address indexed recipient, uint256 amount);

  /// @notice Emitted when a dust withdrawal is initiated at the Gateway
  /// @param amount The amount of dust being withdrawn
  event DustWithdrawalInitiated(uint256 amount);

  /// @dev Emitted when funds are invested
  /// @param amount The amount of funds invested
  event Invested(uint256 amount);

  /// @dev Emitted when funds are divested
  /// @param amount The amount of funds divested
  /// @param fee The fee pre-paid by the caller to keep the Hub's swept accounting exact
  event Divested(uint256 amount, uint256 fee);

  /// @dev Emitted when the excess funds from the current operation are re-deposited into the Gateway
  /// @param amount The amount of funds re-deposited
  event Redeposited(uint256 amount);

  /// @dev Emitted when the minimum delay between invests is updated
  /// @param oldInvestMinDelay The old minimum delay
  /// @param investMinDelay The new minimum delay
  event SetInvestMinDelay(uint256 oldInvestMinDelay, uint256 investMinDelay);

  /// @dev Emitted when the maximum allowed burn intent fee is updated
  /// @param oldMaxFee The old maximum fee
  /// @param maxFee The new maximum fee
  event SetMaxFee(uint256 oldMaxFee, uint256 maxFee);

  /// @dev Emitted when the exposure cap (in absolute terms) is updated
  /// @param oldExposureCapAbs The old exposure cap
  /// @param exposureCapAbs The new exposure cap
  event SetExposureCapAbs(uint256 oldExposureCapAbs, uint256 exposureCapAbs);

  /// @dev Emitted when the exposure cap (in BPS of supplied assets) is updated
  /// @param oldExposureCapBps The old exposure cap
  /// @param exposureCapBps The new exposure cap
  event SetExposureCapBps(uint256 oldExposureCapBps, uint256 exposureCapBps);

  /// @dev Emitted when the liquid buffer (in BPS) is updated
  /// @param oldLiquidBufferBps The old liquid buffer
  /// @param liquidBufferBps The new liquid buffer
  event SetLiquidBufferBps(uint256 oldLiquidBufferBps, uint256 liquidBufferBps);

  /// @dev Emitted when withdrawn funds are returned to the Hub, by {withdraw} or by {claimDust}
  /// @param reclaimedAmount The amount of funds reclaimed by the Hub
  event WithdrawalCompleted(uint256 reclaimedAmount);

  /// @dev Emitted when an on-chain withdrawal is initiated
  /// @param amount The amount of funds withdrawn
  event WithdrawalInitiated(uint256 amount);

  /// @notice Initializes the controller's roles and investment limits
  /// @dev Callable once, on a proxy. The implementation itself is locked at construction,
  /// and the protocol addresses (GATEWAY_WALLET, GATEWAY_MINTER, HUB, USDC, ASSET_ID, DOMAIN) are
  /// fixed there rather than
  /// here, so changing one requires deploying a new implementation and upgrading to it.
  /// @param admin The address granted both DEFAULT_ADMIN_ROLE and KEEPER_ROLE
  /// @param investMinDelay_ The initial minimum delay between invests (in seconds)
  /// @param exposureCapAbs_ The initial exposure cap (in absolute terms)
  /// @param exposureCapBps_ The initial exposure cap (in BPS of supplied assets)
  /// @param maxFee_ The initial maximum fee payable on a withdrawal (in absolute terms)
  /// @param liquidBufferBps_ The initial liquid buffer (in BPS)
  function initialize(
    address admin,
    uint256 investMinDelay_,
    uint256 exposureCapAbs_,
    uint256 exposureCapBps_,
    uint256 maxFee_,
    uint256 liquidBufferBps_
  ) external;

  /// @notice Invests amount of funds into USDC Gateway
  /// @dev The relative limits are evaluated against the Hub's balances at call time, so a keeper
  /// that temporarily inflates supplied assets or idle liquidity can invest beyond
  /// {getExposureCapBps} and {getLiquidBufferBps}.
  /// {getExposureCapAbs} does not move within a transaction and is what bounds the position as an
  /// absolute cap.
  /// @param amount Amount of USDC to invest
  function invest(uint256 amount) external;

  /// @notice Divests amount of funds from USDC Gateway
  /// @dev Bounded by the swept balance less {maxFee}, which is what a full exit divests.
  /// {isValidSignature} applies the same bound with the configured {maxFee} rather than the
  /// intent's own, so every intent it accepts yields an attestation {divest} can consume. Circle
  /// caps attestation size off-chain, and the Gateway contracts impose no on-chain limit.
  /// @dev The attestation names this contract as recipient, so the mint lands here and is then
  /// transferred on to the Hub, rather than naming the Hub directly and letting {reclaim} find
  /// the funds already there. {reclaim} only requires the Hub's aggregate balance to cover the
  /// reclaimed amount, a floor any unrelated USDC satisfies, so routing the mint through this
  /// contract is what proves the funds returned are the funds withdrawn. It also keeps every
  /// field of the transfer spec pinned to `self`
  /// @dev The caller must hold and have approved {maxFee} of USDC. It is forwarded to the Hub
  /// alongside the minted amount, because the Gateway debits `amount + fee` when Circle later
  /// burns. Circle charges a flat fee equal to {maxFee} today, so the two match and nothing is
  /// left behind. Were it ever to charge less, that lower fee would not be knowable here, since
  /// Circle may settle the burn only after issuing the attestation. {maxFee} is charged
  /// regardless, which errs toward over-funding the Hub rather than under-funding it, and
  /// strands the difference in the Gateway
  /// @param amount The amount of funds to withdraw
  /// @param attestationPayload The specification of the withdrawal
  /// @param signature The signature that validates attestation was originated by authorized entity
  function divest(
    uint256 amount,
    bytes calldata attestationPayload,
    bytes calldata signature
  ) external;

  /// @notice Initiates an on-chain withdrawal of the Gateway balance, capped at the swept amount
  /// @dev Only while paused, so no new burn intent validates and no attestation is consumed
  /// against the balance being moved. A burn whose mint finalized before the pause may still land
  /// during the withdrawal delay. Capping the withdrawal at `swept` leaves exactly that pending burn
  /// in the available balance, so it only reaches the withdrawing balance if Circle charges more
  /// than {divest} pre-paid, as after lowering {maxFee} without draining first. The available balance can exceed what the Hub swept, either
  /// through a third-party `depositFor`, which is permissionless, or through {divest} pre-paying
  /// a fee higher than Circle charged. Neither is reclaimable, since the Hub can only take back
  /// what it swept, so the excess is left in the Gateway
  function initiateWithdrawal() external;

  /// @notice Finalizes a pending withdrawal after required time has elapsed
  /// @dev Returns the withdrawn funds to the Hub, capped at `swept`, since {reclaim} can only take
  /// back what was swept. A withdrawal queued by {initiateWithdrawal} never exceeds `swept`, so the
  /// cap only binds when finalizing a dust withdrawal. Any excess is deposited back into the
  /// Gateway, where it covers a burn still pending against it or is left as dust. With `swept` at
  /// zero the Hub is not called and the whole withdrawal is deposited back.
  /// {reclaim} is restricted to the Hub's configured controller, so repointing the Hub at a
  /// different controller while a withdrawal is pending makes this revert until it is pointed back.
  /// The funds remain claimable in the Gateway; a state this code cannot resolve can be addressed by upgrading it.
  function withdraw() external;

  /// @notice Initiates a claim on dust held on the Gateway
  /// As the contract potentially overpays fees if they are lower than max fee, a certain amount accumulates on the
  /// Gateway that can only be claimed by this function, as the other paths use the HUB.reclaim() functionality and
  /// check the accounting against that balance.
  /// @dev Sizes the withdrawal as `available - swept`, which measures surplus only once every burn
  /// has settled. {divest} lowers `swept` when it mints, while the Gateway balance drops later when
  /// Circle burns, so in between the difference is money already owed and this queues too much.
  /// If a burn lands against it during the withdrawal delay, {claimDust} returns the withdrawal to
  /// the Hub instead of paying it out
  function initiateDustWithdrawal() external;

  /// @notice Completes a pending dust withdrawal and forwards it to `recipient`, unless a burn has
  /// landed against it. The dust is not reclaimed to the Hub, as it was never counted as swept.
  /// @dev Requires a dust withdrawal to be pending, so it cannot pay out one queued by
  /// {initiateWithdrawal}. If the Gateway's available balance no longer covers `swept`, a burn has
  /// landed against the queued amount, which therefore holds money owed to Circle, possibly for
  /// further burns still pending. Nothing is paid out then: the withdrawal is finalized as {withdraw}
  /// does, returning it to the Hub up to `swept` and depositing any excess back into the Gateway.
  /// Real dust is left over-backing `swept`, and a later {initiateDustWithdrawal} collects it
  /// @dev Assumes every burn lands before the claim. A burn still pending at the claim leaves no
  /// trace in `available`, and neither does one that landed while `swept` is zero or whose debit a
  /// donation offset. Its funds are then paid out, leaving `swept` unbacked once it lands, or,
  /// with `swept` at zero, leaving the burn short with the Hub unaffected
  /// @dev `recipient` must hold DEFAULT_ADMIN_ROLE, a sanity check against paying dust out to a
  /// mistyped address
  /// @param recipient The address to receive the dust
  function claimDust(address recipient) external;

  /// @notice Halts {invest}, {divest} and {isValidSignature}
  /// @dev Blocking {isValidSignature} stops new burn intents from validating, and blocking {divest}
  /// stops attestations from being consumed. Circle burns only after observing a mint of the
  /// intent in a finalized block, and every mint goes through {divest}, so pausing also holds back
  /// the burn of any intent not yet minted. A burn whose mint already finalized still lands, which
  /// settles accounting {divest} already recorded. The Gateway accepts the TEE's signature at burn
  /// time without calling {isValidSignature} again, and RPC lag may let the TEE briefly approve
  /// against pre-pause state. Withdrawal paths stay open so funds can always be returned to the Hub
  function pause() external;

  /// @notice Resumes {invest}, {divest} and {isValidSignature}
  /// @dev Restricted to DEFAULT_ADMIN_ROLE, so a PAUSER_ROLE holder cannot undo its own halt.
  /// Blocked while an on-chain withdrawal is in flight, since those funds have left the
  /// Gateway's available balance and can no longer back a burn until {withdraw} completes
  function unpause() external;

  /// @notice Sets a new minimum delay between invests (in seconds)
  /// @param investMinDelay_ The new minimum delay between invests (in seconds)
  function setInvestMinDelay(uint256 investMinDelay_) external;

  /// @notice Sets the liquid buffer that must be left on the Hub uninvested (in BPS)
  /// @param liquidBufferBps The new liquid buffer (in BPS)
  function setLiquidBufferBps(uint256 liquidBufferBps) external;

  /// @notice Sets the maximum fee that can be paid to the Gateway operator on a withdrawal
  /// Can be set to 0 to reject any fee-bearing withdrawal
  /// @dev Only while paused. {divest} pre-pays the current {maxFee}, but Circle charges up to the
  /// `maxFee` of the burn intent it attested, which {isValidSignature} checked against the cap at
  /// signing time. An attestation carries no fee field, so {divest} cannot detect a cap that moved
  /// in between. Pausing stops new intents validating and stops {divest} consuming attestations
  /// while the change lands
  /// @dev Pausing does not invalidate intents already attested. To lower the cap: let outstanding
  /// intents settle through {divest} first, then pause, then lower. That order matters, as {divest}
  /// is itself `whenNotPaused`, so pausing first blocks the settlement that has to happen. A lower
  /// cap otherwise makes {divest} pre-pay less than Circle can still charge against an intent
  /// signed under the old one. Raising the cap needs no draining: it only makes {divest}
  /// over-pay, which cannot leave the Hub's `swept` overstated. An attestation whose amount falls
  /// within the increase of the swept balance becomes unusable, since its amount is fixed, and has
  /// to be re-requested
  /// @param maxFee_ The new maximum fee (in absolute terms)
  function setMaxFee(uint256 maxFee_) external;

  /// @notice Sets the exposure cap (in absolute terms)
  /// Can be set to 0 to sunset ReinvestmentController
  /// @param newExposureCapAbs The new exposure cap
  function setExposureCapAbs(uint256 newExposureCapAbs) external;

  /// @notice Sets the exposure cap (in BPS of supplied assets)
  /// @param newExposureCapBps The new exposure cap
  function setExposureCapBps(uint256 newExposureCapBps) external;

  /// @notice Returns the identifier of the KEEPER Role
  /// @return The bytes32 id hash of the KEEPER_ROLE
  function KEEPER_ROLE() external view returns (bytes32);

  /// @notice Returns the identifier of the PAUSER Role
  /// @return The bytes32 id hash of the PAUSER_ROLE
  function PAUSER_ROLE() external view returns (bytes32);

  /// @notice Returns the address of the Circle Gateway wallet, which holds deposits and
  /// serves the on-chain withdrawal path
  /// @return The address of the Gateway wallet
  function GATEWAY_WALLET() external view returns (IGatewayWallet);

  /// @notice Returns the address of the Circle Gateway minter, which mints against
  /// signed attestations
  /// @return The address of the Gateway minter
  function GATEWAY_MINTER() external view returns (IGatewayMinter);

  /// @notice Returns the Circle Gateway domain of this chain, read from the Gateway wallet
  /// @return The Gateway domain
  function DOMAIN() external view returns (uint32);

  /// @notice Returns the address of the Hub
  /// @return The address of the Hub
  function HUB() external view returns (IHub);

  /// @notice Returns the address of the USDC token
  /// @return The address of USDC
  function USDC() external view returns (IERC20);

  /// @notice Returns the ID of the USDC asset on the Hub
  /// @return The asset ID
  function ASSET_ID() external view returns (uint256);

  /// @notice Returns the amount available to invest at any given time
  /// @return The investable amount
  function getInvestableAmount() external view returns (uint256);

  /// @notice Returns the amount of funds currently invested
  /// @return The amount invested
  function getInvestedAmount() external view returns (uint256);

  /// @notice Validates an ERC-1271 signature over a Circle Gateway burn intent
  /// @dev Called off-chain by Circle's TEE, against a quorum of RPCs, to confirm this contract
  /// authorized a withdrawal, as the contract is the depositor, recipient and signer of every burn
  /// intent it submits. The Gateway does not call it again at burn time, as the TEE's signature
  /// stands as proof the check passed.
  /// The burn intent is re-hashed against the Gateway's domain separator and must match
  /// `hash`, the recovered signer must hold KEEPER_ROLE, and the intent itself must pass
  /// the non-zero value, empty hook data, domain, Gateway contract, token, counterparty and
  /// balance checks applied on submission.
  /// Reverts on any failure rather than returning a non-magic selector, so a call that
  /// returns at all returns `IERC1271.isValidSignature.selector`.
  /// @param hash The EIP-712 digest the Gateway expects to have been signed
  /// @param signature abi.encode(bytes adminSignature, bytes burnIntentPayload), where
  /// `adminSignature` is an ECDSA signature over `hash` and `burnIntentPayload` is the
  /// burn intent that signature authorizes
  /// @return `IERC1271.isValidSignature.selector` when the signature is valid
  function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);

  /// @notice Returns the minimum delay between invests
  /// @return The minimum delay (in seconds)
  function getInvestMinDelay() external view returns (uint256);

  /// @notice Returns the timestamp of the most recent invest, or zero if never invested
  /// @dev The next {invest} is allowed once `getLastInvestTimestamp() + getInvestMinDelay()`
  /// has been reached
  /// @return The timestamp at which {invest} was last called
  function getLastInvestTimestamp() external view returns (uint256);

  /// @notice Returns the maximum fee payable to the Gateway operator on a withdrawal
  /// @dev Compared against the `maxFee` field of a burn intent, which bounds what the operator
  /// may charge. The Gateway wallet debits `value + fee`, so the fee is drawn from the invested
  /// balance on top of the amount withdrawn
  /// @return The maximum fee (in absolute terms)
  function getMaxFee() external view returns (uint256);

  /// @notice Returns the amount queued by {initiateDustWithdrawal} and not yet claimed
  /// @dev Zero when no withdrawal is pending, and zero while a principal withdrawal is pending,
  /// which is what {claimDust} checks to tell the two paths apart. The exception is a dust
  /// withdrawal a burn took whole, which is still reported until {unpause} or
  /// {initiateWithdrawal} clears it, or {initiateDustWithdrawal} replaces it
  /// @return The pending dust amount
  function getPendingDust() external view returns (uint256);

  /// @notice Returns the exposure cap (in absolute terms)
  /// @dev Can be set to zero to sunset ReinvestmentController
  /// @return The exposure cap
  function getExposureCapAbs() external view returns (uint256);

  /// @notice Returns the exposure cap (in BPS of supplied assets)
  /// @return The exposure cap
  function getExposureCapBps() external view returns (uint256);

  /// @notice Returns the minimum amount that must remain uninvested in the Hub
  /// @return The amount that must remain uninvested (in BPS)
  function getLiquidBufferBps() external view returns (uint256);
}

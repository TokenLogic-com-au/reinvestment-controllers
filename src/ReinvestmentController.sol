// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {IERC1271} from '@openzeppelin/contracts/interfaces/IERC1271.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {AccessControlUpgradeable} from '@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';
import {Initializable} from '@openzeppelin/contracts/proxy/utils/Initializable.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import {ECDSA} from '@openzeppelin/contracts/utils/cryptography/ECDSA.sol';
import {AttestationLib} from '@circle-gateway/src/lib/AttestationLib.sol';
import {BurnIntentLib} from '@circle-gateway/src/lib/BurnIntentLib.sol';
import {TransferSpecLib} from '@circle-gateway/src/lib/TransferSpecLib.sol';
import {AddressLib} from '@circle-gateway/src/lib/AddressLib.sol';
import {Cursor} from '@circle-gateway/src/lib/Cursor.sol';
import {IHub} from 'aave-v4/hub/interfaces/IHub.sol';
import {PercentageMath} from 'aave-v4/libraries/math/PercentageMath.sol';

import {IGatewayMinter} from './interfaces/IGatewayMinter.sol';
import {IGatewayWallet} from './interfaces/IGatewayWallet.sol';
import {IReinvestmentController} from './interfaces/IReinvestmentController.sol';

contract ReinvestmentController is
  Initializable,
  AccessControlUpgradeable,
  PausableUpgradeable,
  IReinvestmentController
{
  using SafeERC20 for IERC20;
  using TransferSpecLib for bytes29;
  using PercentageMath for uint256;

  /// @inheritdoc IReinvestmentController
  bytes32 public constant KEEPER_ROLE = keccak256('KEEPER_ROLE');

  /// @inheritdoc IReinvestmentController
  bytes32 public constant PAUSER_ROLE = keccak256('PAUSER_ROLE');

  /// @inheritdoc IReinvestmentController
  IGatewayWallet public immutable GATEWAY_WALLET;

  /// @inheritdoc IReinvestmentController
  IGatewayMinter public immutable GATEWAY_MINTER;

  /// @inheritdoc IReinvestmentController
  uint32 public immutable DOMAIN;

  /// @inheritdoc IReinvestmentController
  IHub public immutable HUB;

  /// @inheritdoc IReinvestmentController
  IERC20 public immutable USDC;

  /// @inheritdoc IReinvestmentController
  uint256 public immutable ASSET_ID;

  /// @custom:storage-location erc7201:reinvestment.storage.ReinvestmentController
  struct ReinvestmentControllerStorage {
    /// @dev Minimum time that must elapse between invests (in seconds)
    uint256 investMinDelay;
    /// @dev Timestamp of last invest
    uint256 lastInvestTimestamp;
    /// @dev Liquid buffer of uninvested funds on Hub (in BPS)
    uint256 liquidBufferBps;
    /// @dev Exposure cap (in absolute terms)
    uint256 exposureCapAbs;
    /// @dev Exposure cap (in BPS of supplied assets)
    uint256 exposureCapBps;
    /// @dev Maximum fee payable to the Gateway operator on a withdrawal (in absolute terms)
    uint256 maxFee;
    /// @dev Amount queued by {initiateDustWithdrawal}, zero when the pending withdrawal is principal
    uint256 pendingDust;
  }

  /// @dev The storage slot for the ReinvestmentController storage struct.
  bytes32 private constant NAMESPACE_SLOT =
    // keccak256(abi.encode(uint256(keccak256("reinvestment.storage.ReinvestmentController")) - 1)) & ~bytes32(uint256(0xff))
    0x65dc087072dd8c0d5c42256b2a3653a05a0be68d693649cbc5ae4d5c285c5d00;

  /// @dev Loads the ReinvestmentController storage struct.
  function _getReinvestmentControllerStorage()
    private
    pure
    returns (ReinvestmentControllerStorage storage $)
  {
    assembly ('memory-safe') {
      $.slot := NAMESPACE_SLOT
    }
  }

  /// @dev Sets the immutable protocol addresses and locks the implementation. The
  /// resulting contract is inert until {initialize} is called on a proxy in front of it.
  /// @param gatewayWallet The address of the Circle Gateway wallet
  /// @param gatewayMinter The address of the Circle Gateway minter
  /// @param hub The address of the Hub
  /// @param usdc The address of the USDC token
  constructor(address gatewayWallet, address gatewayMinter, address hub, address usdc) {
    require(
      gatewayWallet != address(0) &&
        gatewayMinter != address(0) &&
        hub != address(0) &&
        usdc != address(0),
      InvalidZeroAddress()
    );
    require(gatewayWallet != gatewayMinter, InvalidGatewayConfiguration());

    GATEWAY_WALLET = IGatewayWallet(gatewayWallet);
    GATEWAY_MINTER = IGatewayMinter(gatewayMinter);
    HUB = IHub(hub);
    USDC = IERC20(usdc);
    ASSET_ID = IHub(hub).getAssetId(usdc);
    DOMAIN = IGatewayWallet(gatewayWallet).domain();

    require(IGatewayMinter(gatewayMinter).domain() == DOMAIN, InvalidDomain());
    require(
      IGatewayWallet(gatewayWallet).domainSeparator() != bytes32(0),
      InvalidGatewayConfiguration()
    );
    require(IGatewayWallet(gatewayWallet).isTokenSupported(usdc), InvalidGatewayConfiguration());
    require(IGatewayMinter(gatewayMinter).isTokenSupported(usdc), InvalidGatewayConfiguration());

    _disableInitializers();
  }

  /// @inheritdoc IReinvestmentController
  function initialize(
    address admin,
    uint256 investMinDelay,
    uint256 exposureCapAbs,
    uint256 exposureCapBps,
    uint256 maxFee,
    uint256 liquidBufferBps
  ) external initializer {
    require(admin != address(0), InvalidZeroAddress());

    __AccessControl_init();
    __Pausable_init();

    _grantRole(DEFAULT_ADMIN_ROLE, admin);
    _grantRole(KEEPER_ROLE, admin);
    _grantRole(PAUSER_ROLE, admin);

    _setInvestMinDelay(investMinDelay);
    _setExposureCapAbs(exposureCapAbs);
    _setExposureCapBps(exposureCapBps);
    _setMaxFee(maxFee);
    _setLiquidBufferBps(liquidBufferBps);
  }

  /// @inheritdoc IReinvestmentController
  function invest(uint256 amount) external onlyRole(KEEPER_ROLE) whenNotPaused {
    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    require(
      block.timestamp >= $.lastInvestTimestamp + $.investMinDelay,
      InvestMinDelayNotElapsed()
    );
    require(amount > 0, InvalidAmount());
    require(amount <= _getInvestableAmount(), ExposureCapExceeded());

    $.lastInvestTimestamp = block.timestamp;

    HUB.sweep(ASSET_ID, amount);
    USDC.forceApprove(address(GATEWAY_WALLET), amount);
    GATEWAY_WALLET.deposit(address(USDC), amount);

    emit Invested(amount);
  }

  /// @inheritdoc IReinvestmentController
  function divest(
    uint256 amount,
    bytes memory attestationPayload,
    bytes memory signature
  ) external onlyRole(KEEPER_ROLE) whenNotPaused {
    require(amount > 0, InvalidAmount());

    uint256 fee = _getReinvestmentControllerStorage().maxFee;
    uint256 total = amount + fee;
    require(total <= HUB.getAssetSwept(ASSET_ID), InsufficientLiquidity());

    _validateAttestation(attestationPayload, amount);

    GATEWAY_MINTER.gatewayMint(attestationPayload, signature);

    if (fee > 0) {
      USDC.safeTransferFrom(msg.sender, address(this), fee);
    }

    USDC.safeTransfer(address(HUB), total);
    HUB.reclaim(ASSET_ID, total);

    emit Divested(amount, fee);
  }

  /// @inheritdoc IReinvestmentController
  function initiateWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
    _requireNoPendingWithdrawal();

    uint256 amount = Math.min(_availableBalance(), HUB.getAssetSwept(ASSET_ID));

    require(amount > 0, InvalidAmount());

    GATEWAY_WALLET.initiateWithdrawal(address(USDC), amount);

    emit WithdrawalInitiated(amount);
  }

  /// @inheritdoc IReinvestmentController
  function withdraw() external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 withdrawingBalance = _withdrawingBalance();

    require(withdrawingBalance > 0, NoWithdrawalInProcess());

    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();
    if ($.pendingDust > 0) {
      $.pendingDust = 0;
    }

    GATEWAY_WALLET.withdraw(address(USDC));

    _cappedReclaim(withdrawingBalance);
  }

  /// @inheritdoc IReinvestmentController
  function initiateDustWithdrawal() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
    _requireNoPendingWithdrawal();

    uint256 dust = Math.saturatingSub(_availableBalance(), HUB.getAssetSwept(ASSET_ID));

    require(dust > 0, NoDust());

    _getReinvestmentControllerStorage().pendingDust = dust;

    GATEWAY_WALLET.initiateWithdrawal(address(USDC), dust);

    emit DustWithdrawalInitiated(dust);
  }

  /// @inheritdoc IReinvestmentController
  function claimDust(address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
    require(recipient != address(0), InvalidZeroAddress());
    require(hasRole(DEFAULT_ADMIN_ROLE, recipient), InvalidRecipient());

    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    require($.pendingDust > 0, NoDustWithdrawalInProcess());

    uint256 withdrawingBalance = _withdrawingBalance();
    $.pendingDust = 0;

    GATEWAY_WALLET.withdraw(address(USDC));

    if (_availableBalance() < HUB.getAssetSwept(ASSET_ID)) {
      _cappedReclaim(withdrawingBalance);
      return;
    }

    USDC.safeTransfer(recipient, withdrawingBalance);
    emit ClaimedDust(recipient, withdrawingBalance);
  }

  /// @inheritdoc IReinvestmentController
  function pause() external onlyRole(PAUSER_ROLE) {
    _pause();
  }

  /// @inheritdoc IReinvestmentController
  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_withdrawingBalance() == 0, WithdrawalInProcess());

    _unpause();
  }

  /// @inheritdoc IReinvestmentController
  function setInvestMinDelay(uint256 investMinDelay_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setInvestMinDelay(investMinDelay_);
  }

  /// @inheritdoc IReinvestmentController
  function setLiquidBufferBps(uint256 liquidBufferBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setLiquidBufferBps(liquidBufferBps_);
  }

  /// @inheritdoc IReinvestmentController
  function setMaxFee(uint256 maxFee_) external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
    _setMaxFee(maxFee_);
  }

  /// @inheritdoc IReinvestmentController
  function setExposureCapAbs(uint256 newExposureCapAbs) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setExposureCapAbs(newExposureCapAbs);
  }

  /// @inheritdoc IReinvestmentController
  function setExposureCapBps(uint256 newExposureCapBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
    _setExposureCapBps(newExposureCapBps);
  }

  /// @inheritdoc IReinvestmentController
  function getInvestableAmount() external view returns (uint256) {
    return _getInvestableAmount();
  }

  /// @inheritdoc IReinvestmentController
  function getInvestedAmount() external view returns (uint256) {
    return HUB.getAssetSwept(ASSET_ID);
  }

  /// @inheritdoc IReinvestmentController
  function getInvestMinDelay() external view returns (uint256) {
    return _getReinvestmentControllerStorage().investMinDelay;
  }

  /// @inheritdoc IReinvestmentController
  function getLastInvestTimestamp() external view returns (uint256) {
    return _getReinvestmentControllerStorage().lastInvestTimestamp;
  }

  /// @inheritdoc IReinvestmentController
  function getMaxFee() external view returns (uint256) {
    return _getReinvestmentControllerStorage().maxFee;
  }

  /// @inheritdoc IReinvestmentController
  function getPendingDust() external view returns (uint256) {
    return _getReinvestmentControllerStorage().pendingDust;
  }

  /// @inheritdoc IReinvestmentController
  function getExposureCapAbs() external view returns (uint256) {
    return _getReinvestmentControllerStorage().exposureCapAbs;
  }

  /// @inheritdoc IReinvestmentController
  function getExposureCapBps() external view returns (uint256) {
    return _getReinvestmentControllerStorage().exposureCapBps;
  }

  /// @inheritdoc IReinvestmentController
  function getLiquidBufferBps() external view returns (uint256) {
    return _getReinvestmentControllerStorage().liquidBufferBps;
  }

  /// @inheritdoc IReinvestmentController
  function isValidSignature(
    bytes32 hash,
    bytes calldata signatureData
  ) external view whenNotPaused returns (bytes4) {
    (bytes memory keeperSignature, bytes memory burnIntentPayload) = abi.decode(
      signatureData,
      (bytes, bytes)
    );

    bytes32 structHash = BurnIntentLib.getTypedDataHash(burnIntentPayload);
    bytes32 digest = MessageHashUtils.toTypedDataHash(GATEWAY_WALLET.domainSeparator(), structHash);
    require(digest == hash, HashMismatch());

    address recoveredSigner = ECDSA.recover(digest, keeperSignature);
    require(hasRole(KEEPER_ROLE, recoveredSigner), InvalidSignature());

    _validateBurnIntent(burnIntentPayload);

    return IERC1271.isValidSignature.selector;
  }

  /// @dev Sets a new minimum delay between invests (in seconds)
  /// @param investMinDelay_ The new minimum delay between invests (in seconds)
  function _setInvestMinDelay(uint256 investMinDelay_) internal {
    require(investMinDelay_ > 0, InvalidAmount());

    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    uint256 oldInvestMinDelay = $.investMinDelay;
    $.investMinDelay = investMinDelay_;
    emit SetInvestMinDelay(oldInvestMinDelay, investMinDelay_);
  }

  /// @dev Sets the liquid buffer that must be left on the Hub uninvested (in BPS)
  /// @param liquidBufferBps New liquid buffer (in BPS)
  function _setLiquidBufferBps(uint256 liquidBufferBps) internal {
    require(
      liquidBufferBps > 0 && liquidBufferBps < PercentageMath.PERCENTAGE_FACTOR,
      InvalidAmount()
    );

    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    uint256 oldLiquidBufferBps = $.liquidBufferBps;
    $.liquidBufferBps = liquidBufferBps;
    emit SetLiquidBufferBps(oldLiquidBufferBps, liquidBufferBps);
  }

  /// @dev Sets the maximum fee payable to the Gateway operator on a withdrawal
  /// Can be set to 0 to reject any fee-bearing withdrawal
  /// @param maxFee_ The new maximum fee (in absolute terms)
  function _setMaxFee(uint256 maxFee_) internal {
    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    uint256 oldMaxFee = $.maxFee;
    $.maxFee = maxFee_;
    emit SetMaxFee(oldMaxFee, maxFee_);
  }

  /// @dev Sets the exposure cap (in absolute terms)
  /// Can be set to 0 to sunset ReinvestmentController
  /// @param newExposureCapAbs The new exposure cap
  function _setExposureCapAbs(uint256 newExposureCapAbs) internal {
    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    uint256 oldExposureCapAbs = $.exposureCapAbs;
    $.exposureCapAbs = newExposureCapAbs;
    emit SetExposureCapAbs(oldExposureCapAbs, newExposureCapAbs);
  }

  /// @dev Sets the exposure cap (in BPS of supplied assets)
  /// @param newExposureCapBps The new exposure cap
  function _setExposureCapBps(uint256 newExposureCapBps) internal {
    require(
      newExposureCapBps > 0 && newExposureCapBps < PercentageMath.PERCENTAGE_FACTOR,
      InvalidAmount()
    );

    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    uint256 oldExposureCapBps = $.exposureCapBps;
    $.exposureCapBps = newExposureCapBps;
    emit SetExposureCapBps(oldExposureCapBps, newExposureCapBps);
  }

  /// @dev Refuses to stack a withdrawal on top of another. Checked before either path (dust/withdraw)
  /// sizes its amount, as a pending withdrawal leaves the available balance empty and would otherwise
  /// surface as an empty-amount error instead
  function _requireNoPendingWithdrawal() internal view {
    require(_withdrawingBalance() == 0, WithdrawalInProcess());
  }

  /// @dev The Gateway balance still backing the Hub's swept amount
  function _availableBalance() internal view returns (uint256) {
    return GATEWAY_WALLET.availableBalance(address(USDC), address(this));
  }

  /// @dev The Gateway balance reserved by an in-progress withdrawal
  function _withdrawingBalance() internal view returns (uint256) {
    return GATEWAY_WALLET.withdrawingBalance(address(USDC), address(this));
  }

  /// @dev Calculates the amount currently available to invest
  function _getInvestableAmount() internal view returns (uint256) {
    uint256 supplied = HUB.getAddedAssets(ASSET_ID);
    ReinvestmentControllerStorage storage $ = _getReinvestmentControllerStorage();

    // This is the amount of idle assets on Hub that can be
    // invested without violating the liquid buffer (percentage
    // of supplied assets that must always remain idle on Hub).
    uint256 freeIdle;
    {
      uint256 liquidBuffer = supplied.percentMulUp($.liquidBufferBps);
      uint256 idle = HUB.getAssetLiquidity(ASSET_ID);
      freeIdle = Math.saturatingSub(idle, liquidBuffer);
    }
    // This is the maximum amount that can be invested without
    // exceeding the exposure cap.
    uint256 residualExposureCap;
    {
      uint256 exposureCapRel = supplied.percentMulDown($.exposureCapBps);
      uint256 cap = Math.min($.exposureCapAbs, exposureCapRel);
      uint256 swept = HUB.getAssetSwept(ASSET_ID);
      residualExposureCap = Math.saturatingSub(cap, swept);
    }

    // We conservatively return the minimum of the two amounts.
    return Math.min(freeIdle, residualExposureCap);
  }

  /// @dev Validates an attestation that was signed to withdraw funds
  /// @param attestationPayload Payload containing signed transfer specification
  /// @param amount Amount of token to withdraw
  function _validateAttestation(bytes memory attestationPayload, uint256 amount) internal view {
    Cursor memory cursor = AttestationLib.cursor(attestationPayload);
    require(cursor.numElements == 1, InvalidElementCount());

    bytes29 spec = AttestationLib.getTransferSpec(AttestationLib.next(cursor));
    _validateTransferSpec(address(USDC), spec);

    require(spec.getValue() == amount, InvalidMintAmount());
  }

  /// @dev Validates a withdrawal (BurnIntent) prior to signing an attestation
  /// @param burnIntentPayload Payload containing withdrawal specification
  function _validateBurnIntent(bytes memory burnIntentPayload) internal view {
    Cursor memory cursor = BurnIntentLib.cursor(burnIntentPayload);
    require(cursor.numElements == 1, InvalidElementCount());

    bytes29 intent = BurnIntentLib.next(cursor);
    bytes29 spec = BurnIntentLib.getTransferSpec(intent);
    _validateTransferSpec(address(USDC), spec);

    uint256 maxFee = _getReinvestmentControllerStorage().maxFee;
    uint256 intentMaxFee = BurnIntentLib.getMaxFee(intent);
    require(intentMaxFee <= maxFee, MaxFeeExceeded());

    require(spec.getValue() + maxFee <= HUB.getAssetSwept(ASSET_ID), BurnIntentExceedsBalance());
  }

  /// @dev Validates the parameters of a withdrawal (BurnIntent)
  /// @param token Address of the token to withdraw
  /// @param spec The bytes29 representation of the burn intent
  function _validateTransferSpec(address token, bytes29 spec) internal view {
    bytes32 expectedToken = AddressLib._addressToBytes32(token);
    bytes32 self = AddressLib._addressToBytes32(address(this));

    require(spec.getValue() > 0, InvalidAmount());
    require(spec.getHookDataLength() == 0, InvalidHookData());
    require(spec.getSourceDomain() == spec.getDestinationDomain(), CrossChainTransferNotAllowed());
    require(spec.getSourceDomain() == DOMAIN, InvalidDomain());
    require(
      spec.getSourceContract() == AddressLib._addressToBytes32(address(GATEWAY_WALLET)),
      InvalidSourceContract()
    );
    require(
      spec.getDestinationContract() == AddressLib._addressToBytes32(address(GATEWAY_MINTER)),
      InvalidDestinationContract()
    );
    require(spec.getSourceToken() == expectedToken, InvalidSourceToken());
    require(spec.getDestinationToken() == expectedToken, InvalidDestinationToken());
    require(spec.getSourceDepositor() == self, InvalidDepositor());
    require(spec.getDestinationRecipient() == self, InvalidRecipient());
    require(spec.getSourceSigner() == self, InvalidSigner());
    require(spec.getDestinationCaller() == self, InvalidDestinationCaller());
  }

  /// @dev Returns withdrawn funds to the Hub, capped at `swept` since {reclaim} cannot take back
  /// more, and skipped when `swept` is zero since the Hub rejects a zero reclaim. Any excess is
  /// deposited back into the Gateway, where it covers a burn that may still be pending against it,
  /// or is otherwise left as dust for {initiateDustWithdrawal}
  /// @param withdrawn The amount just withdrawn from the Gateway
  function _cappedReclaim(uint256 withdrawn) internal {
    uint256 reclaimAmount = Math.min(withdrawn, HUB.getAssetSwept(ASSET_ID));

    if (reclaimAmount > 0) {
      USDC.safeTransfer(address(HUB), reclaimAmount);
      HUB.reclaim(ASSET_ID, reclaimAmount);

      emit WithdrawalCompleted(reclaimAmount);
    }

    uint256 excess = withdrawn - reclaimAmount;
    if (excess > 0) {
      USDC.forceApprove(address(GATEWAY_WALLET), excess);
      GATEWAY_WALLET.deposit(address(USDC), excess);
      emit Redeposited(excess);
    }
  }
}

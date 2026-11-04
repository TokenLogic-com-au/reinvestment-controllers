// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @dev Stand-in for Circle's `GatewayWallet`. Mirrors the real two-bucket balance model:
/// `availableBalance` moves into `withdrawingBalance` on `initiateWithdrawal`, `withdraw` pays
/// the latter out, and `gatewayBurn` debits the former first and takes any rest from the latter.
/// Getter names and argument order match the real contract (`token`, `depositor`) so the mock
/// cannot teach a wrong API.
contract MockGatewayWallet {
  using SafeERC20 for IERC20;

  error NoWithdrawingBalance();
  error NotGatewayMinter();
  error WithdrawalNotYetAvailable();
  error WithdrawalValueExceedsAvailableBalance();
  error WithdrawalValueMustBePositive();

  event WithdrawalInitiated(
    address indexed token,
    address indexed depositor,
    uint256 value,
    uint256 remainingAvailable,
    uint256 totalWithdrawing,
    uint256 withdrawalBlock
  );
  event WithdrawalCompleted(address indexed token, address indexed depositor, uint256 value);

  bytes32 public constant EIP712_DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  uint256 public immutable WITHDRAWAL_DELAY;

  address public gatewayMinter;

  uint32 public domain;

  mapping(address token => bool) public isTokenSupported;

  mapping(address token => mapping(address depositor => uint256)) internal _availableBalances;
  mapping(address token => mapping(address depositor => uint256)) internal _withdrawingBalances;
  mapping(address token => mapping(address depositor => uint256)) internal _withdrawalBlocks;

  constructor(uint256 withdrawalDelay_) {
    WITHDRAWAL_DELAY = withdrawalDelay_;
  }

  function deposit(address token, uint256 value) external {
    IERC20(token).safeTransferFrom(msg.sender, address(this), value);
    _availableBalances[token][msg.sender] += value;
  }

  function depositFor(address token, address depositor, uint256 value) external {
    IERC20(token).safeTransferFrom(msg.sender, address(this), value);
    _availableBalances[token][depositor] += value;
  }

  function initiateWithdrawal(address token, uint256 value) external {
    require(value > 0, WithdrawalValueMustBePositive());
    require(
      value <= _availableBalances[token][msg.sender],
      WithdrawalValueExceedsAvailableBalance()
    );

    _availableBalances[token][msg.sender] -= value;
    _withdrawingBalances[token][msg.sender] += value;
    _withdrawalBlocks[token][msg.sender] = block.number + WITHDRAWAL_DELAY;

    emit WithdrawalInitiated(
      token,
      msg.sender,
      value,
      _availableBalances[token][msg.sender],
      _withdrawingBalances[token][msg.sender],
      _withdrawalBlocks[token][msg.sender]
    );
  }

  function withdraw(address token) external {
    require(_withdrawalBlocks[token][msg.sender] <= block.number, WithdrawalNotYetAvailable());

    uint256 value = _withdrawingBalances[token][msg.sender];
    require(value > 0, NoWithdrawingBalance());

    _withdrawingBalances[token][msg.sender] = 0;
    _withdrawalBlocks[token][msg.sender] = 0;

    IERC20(token).safeTransfer(msg.sender, value);

    emit WithdrawalCompleted(token, msg.sender, value);
  }
  /// @dev Transfers to the minter rather than burning. The real system burns here and mints on
  /// the destination domain, but the controller only permits same-domain transfers, so moving
  /// the tokens is equivalent and keeps total supply conserved for the invariant suite.
  function gatewayBurn(address token, address depositor, uint256 value, uint256 fee) external {
    require(msg.sender == gatewayMinter, NotGatewayMinter());

    uint256 total = value + fee;
    uint256 fromAvailable = Math.min(total, _availableBalances[token][depositor]);
    _availableBalances[token][depositor] -= fromAvailable;
    _withdrawingBalances[token][depositor] -= total - fromAvailable;

    IERC20(token).safeTransfer(msg.sender, total);
  }

  function domainSeparator() external view returns (bytes32) {
    return
      keccak256(
        abi.encode(
          EIP712_DOMAIN_TYPEHASH,
          keccak256('GatewayWallet'),
          keccak256('1'),
          block.chainid,
          address(this)
        )
      );
  }

  function availableBalance(address token, address depositor) external view returns (uint256) {
    return _availableBalances[token][depositor];
  }

  function withdrawingBalance(address token, address depositor) external view returns (uint256) {
    return _withdrawingBalances[token][depositor];
  }

  function totalBalance(address token, address depositor) external view returns (uint256) {
    return _availableBalances[token][depositor] + _withdrawingBalances[token][depositor];
  }

  function withdrawalDelay() external view returns (uint256) {
    return WITHDRAWAL_DELAY;
  }

  function withdrawalBlock(address token, address depositor) external view returns (uint256) {
    return _withdrawalBlocks[token][depositor];
  }

  function setTokenSupported(address token, bool supported) external {
    isTokenSupported[token] = supported;
  }

  function setGatewayMinter(address minter) external {
    gatewayMinter = minter;
  }
}

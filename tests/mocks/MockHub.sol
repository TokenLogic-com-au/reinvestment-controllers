// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {MockUSDC} from './MockUSDC.sol';

contract MockHub {
  using SafeERC20 for IERC20;

  error AssetNotListed();
  error InsufficientLiquidity(uint256 liquidity);
  error InvalidAmount();
  error NotReinvestmentController();
  error SweptExceeded(uint256 swept);

  event Sweep(uint256 indexed assetId, address indexed reinvestmentController, uint256 amount);
  event Reclaim(uint256 indexed assetId, address indexed reinvestmentController, uint256 amount);

  uint256 public constant USDC_ASSET_ID = 3;

  MockUSDC public immutable USDC;

  address public reinvestmentController;

  uint256 internal _liquidity;
  uint256 internal _swept;
  uint256 internal _addedAssets;

  constructor(address usdc) {
    USDC = MockUSDC(usdc);
  }

  function sweep(uint256 assetId, uint256 amount) external {
    _checkAsset(assetId);
    require(msg.sender == reinvestmentController, NotReinvestmentController());
    require(amount <= _liquidity, InsufficientLiquidity(_liquidity));

    _liquidity -= amount;
    _swept += amount;

    IERC20(address(USDC)).safeTransfer(msg.sender, amount);

    emit Sweep(assetId, msg.sender, amount);
  }

  /// @dev Accounting only. The controller pushes the tokens back with `safeTransfer` immediately
  /// before calling this, so the mock must not pull them again. The real Hub behaves the same way,
  /// checking its own balance rather than transferring.
  function reclaim(uint256 assetId, uint256 amount) external {
    _checkAsset(assetId);
    require(msg.sender == reinvestmentController, NotReinvestmentController());
    require(amount > 0, InvalidAmount());
    require(amount <= _swept, SweptExceeded(_swept));

    _swept -= amount;
    _liquidity += amount;

    emit Reclaim(assetId, msg.sender, amount);
  }

  function getAssetId(address underlying) external view returns (uint256) {
    require(underlying == address(USDC), AssetNotListed());
    return USDC_ASSET_ID;
  }

  function getAssetLiquidity(uint256 assetId) external view returns (uint256) {
    _checkAsset(assetId);
    return _liquidity;
  }

  function getAssetSwept(uint256 assetId) external view returns (uint256) {
    _checkAsset(assetId);
    return _swept;
  }

  function getAddedAssets(uint256 assetId) external view returns (uint256) {
    _checkAsset(assetId);
    return _addedAssets;
  }

  function setReinvestmentController(address controller) external {
    reinvestmentController = controller;
  }

  function add(uint256 amount) external {
    USDC.mint(address(this), amount);
    _liquidity += amount;
    _addedAssets += amount;
  }

  function remove(uint256 amount) external {
    require(amount <= _liquidity, InsufficientLiquidity(_liquidity));

    _liquidity -= amount;
    _addedAssets -= amount;
    USDC.burn(address(this), amount);
  }

  function setAccounting(uint256 addedAssets_, uint256 liquidity_, uint256 swept_) external {
    _addedAssets = addedAssets_;
    _liquidity = liquidity_;
    _swept = swept_;
  }

  function _checkAsset(uint256 assetId) internal pure {
    require(assetId == USDC_ASSET_ID, AssetNotListed());
  }
}

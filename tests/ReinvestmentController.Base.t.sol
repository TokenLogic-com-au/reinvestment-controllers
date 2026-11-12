// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import {BurnIntentLib} from '@circle-gateway/src/lib/BurnIntentLib.sol';

import {ReinvestmentController} from '../src/ReinvestmentController.sol';
import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {MockGatewayMinter} from './mocks/MockGatewayMinter.sol';
import {MockGatewayWallet} from './mocks/MockGatewayWallet.sol';
import {MockHub} from './mocks/MockHub.sol';
import {MockUSDC} from './mocks/MockUSDC.sol';
import {GatewayPayloads} from './utils/GatewayPayloads.sol';

abstract contract ReinvestmentControllerTestBase is Test, GatewayPayloads {
  uint256 internal constant WITHDRAWAL_DELAY = 7;
  uint256 internal constant INVEST_MIN_DELAY = 1 days;
  uint256 internal constant EXPOSURE_CAP_ABS = 10_000_000e6;
  uint256 internal constant EXPOSURE_CAP_BPS = 8_000;
  uint256 internal constant LIQUID_BUFFER_BPS = 1_000;
  uint256 internal constant MAX_FEE = 0;
  uint256 internal constant PERCENTAGE_FACTOR = 100_00;

  uint256 internal constant SUPPLIED = 1_000_000e6;
  uint256 internal constant BUFFER = 100_000e6;
  uint256 internal constant INVESTABLE = 800_000e6;

  MockUSDC internal usdc;
  MockHub internal hub;
  MockGatewayWallet internal wallet;
  MockGatewayMinter internal minter;

  ReinvestmentController internal implementation;
  ReinvestmentController internal controller;

  uint256 internal assetId;

  address internal admin;
  uint256 internal adminPrivateKey;
  address internal keeper;
  uint256 internal keeperPrivateKey;
  address internal pauser;
  address internal alice;
  uint256 internal alicePrivateKey;

  function setUp() public virtual {
    vm.warp(1_700_000_000);
    vm.roll(21_000_000);

    (admin, adminPrivateKey) = makeAddrAndKey('admin');
    (keeper, keeperPrivateKey) = makeAddrAndKey('keeper');
    (alice, alicePrivateKey) = makeAddrAndKey('alice');
    pauser = makeAddr('pauser');

    usdc = new MockUSDC();
    hub = new MockHub(address(usdc));
    wallet = new MockGatewayWallet(WITHDRAWAL_DELAY);
    minter = new MockGatewayMinter(address(wallet));
    wallet.setGatewayMinter(address(minter));
    wallet.setTokenSupported(address(usdc), true);
    minter.setTokenSupported(address(usdc), true);

    assetId = hub.USDC_ASSET_ID();

    implementation = new ReinvestmentController(
      address(wallet),
      address(minter),
      address(hub),
      address(usdc)
    );

    controller = ReinvestmentController(
      address(
        new ERC1967Proxy(
          address(implementation),
          abi.encodeCall(
            IReinvestmentController.initialize,
            (
              admin,
              INVEST_MIN_DELAY,
              EXPOSURE_CAP_ABS,
              EXPOSURE_CAP_BPS,
              MAX_FEE,
              LIQUID_BUFFER_BPS
            )
          )
        )
      )
    );

    _setPayloadContext(address(wallet), address(minter), address(usdc), address(controller));

    hub.setReinvestmentController(address(controller));
    hub.add(SUPPLIED);

    bytes32 keeperRole = controller.KEEPER_ROLE();
    bytes32 pauserRole = controller.PAUSER_ROLE();

    vm.startPrank(admin);
    controller.grantRole(keeperRole, keeper);
    controller.grantRole(pauserRole, pauser);
    vm.stopPrank();
  }

  function _invest(uint256 amount) internal {
    vm.prank(keeper);
    controller.invest(amount);
  }

  function _donate(uint256 amount) internal {
    usdc.mint(alice, amount);

    vm.startPrank(alice);
    usdc.approve(address(wallet), amount);
    wallet.depositFor(address(usdc), address(controller), amount);
    vm.stopPrank();
  }

  function _pause() internal {
    vm.prank(pauser);
    controller.pause();
  }

  function _unpause() internal {
    vm.prank(admin);
    controller.unpause();
  }

  /// @dev Divests with the burn deferred: the mint lands and {divest} lowers swept by
  /// `amount + maxFee`, but the Gateway balance is untouched until {_burn}. The keeper is funded
  /// with the fee, and the controller must be unpaused
  function _divestWithDeferredBurn(uint256 amount) internal {
    uint256 fee = controller.getMaxFee();

    vm.mockCall(address(minter), abi.encodeWithSelector(minter.gatewayMint.selector), '');
    usdc.mint(address(controller), amount);

    usdc.mint(keeper, fee);
    vm.startPrank(keeper);
    usdc.approve(address(controller), fee);
    controller.divest(amount, _encodeAttestation(_defaultTransferSpec(amount)), hex'1234');
    vm.stopPrank();

    vm.clearMockedCalls();
  }

  /// @dev Settles a burn against the controller's Gateway balance, as Circle does after a mint
  function _burn(uint256 amount, uint256 fee) internal {
    vm.prank(address(minter));
    wallet.gatewayBurn(address(usdc), address(controller), amount, fee);
  }

  function _setMaxFee(uint256 maxFee) internal {
    _pause();
    vm.prank(admin);
    controller.setMaxFee(maxFee);
    _unpause();
  }

  function _signBurnIntent(
    uint256 privateKey,
    bytes memory burnIntentPayload
  ) internal view returns (bytes32 digest, bytes memory signature) {
    digest = MessageHashUtils.toTypedDataHash(
      wallet.domainSeparator(),
      BurnIntentLib.getTypedDataHash(burnIntentPayload)
    );

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
    signature = abi.encode(abi.encodePacked(r, s, v), burnIntentPayload);
  }
}

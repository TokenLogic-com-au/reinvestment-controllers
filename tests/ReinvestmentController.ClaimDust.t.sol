// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerClaimDustTest is ReinvestmentControllerTestBase {
  uint256 internal constant INVESTED = 400_000e6;
  uint256 internal constant DUST = 1_000e6;
  uint256 internal constant CONFIGURED_FEE = 1e6;
  uint256 internal constant CHARGED_FEE = 0.8e6;
  uint256 internal constant DIVESTED = INVESTED - CONFIGURED_FEE;

  function setUp() public override {
    super.setUp();

    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
    vm.prank(admin);
    controller.grantRole(adminRole, alice);

    _invest(INVESTED);
    _donate(DUST);
    _divest(INVESTED);
    _pause();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    vm.roll(block.number + WITHDRAWAL_DELAY);
  }

  function test_claimDust() public {
    vm.expectEmit(address(controller));
    emit IReinvestmentController.ClaimedDust(alice, DUST);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(controller.getPendingDust(), 0);
    assertEq(usdc.balanceOf(alice), DUST);
    assertEq(usdc.balanceOf(address(controller)), 0);
    assertEq(usdc.balanceOf(address(wallet)), 0);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
  }

  function test_claimDust_doesNotReclaimToHub() public {
    uint256 liquidityBefore = hub.getAssetLiquidity(assetId);
    uint256 sweptBefore = hub.getAssetSwept(assetId);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(hub.getAssetLiquidity(assetId), liquidityBefore);
    assertEq(hub.getAssetSwept(assetId), sweptBefore);
    assertEq(usdc.balanceOf(address(hub)), liquidityBefore);
  }

  function test_claimDust_allowsUnpause() public {
    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertFalse(controller.paused());
  }

  /// @dev A burn pending when the dust withdrawal is queued takes its funds from the withdrawing
  /// balance, so only the difference between the configured and the charged fee is paid out
  function test_claimDust_pendingBurnLeavesOnlyFeeDifference() public {
    _divestAllWithDeferredBurn();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(controller.getPendingDust(), INVESTED);

    _burnDivested(CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertEq(usdc.balanceOf(alice) - aliceBefore, CONFIGURED_FEE - CHARGED_FEE);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
  }

  /// @dev A donation made after the dust withdrawal is queued lands in the available balance,
  /// which the pending burn drains first, so it ends up in the withdrawing balance and is paid out
  function test_claimDust_donationDuringPendingBurnIsPaidOut() public {
    _divestAllWithDeferredBurn();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _donate(DUST);
    _burnDivested(CONFIGURED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertEq(usdc.balanceOf(alice) - aliceBefore, DUST);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(hub.getAssetSwept(assetId), 0);
  }

  /// @dev A burn can drain a queued dust withdrawal completely when it holds no real dust. The
  /// stale `pendingDust` then lets {claimDust} reach a later principal withdrawal, and the backing
  /// check is what stops it from paying that out
  function test_claimDust_revertsWith_SweptNotBacked_stalePendingDust() public {
    _divestAllWithDeferredBurn();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burnDivested(CONFIGURED_FEE);

    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(controller.getPendingDust(), INVESTED);

    _reinvest(INVESTED);
    _pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.roll(block.number + WITHDRAWAL_DELAY);

    vm.expectRevert(IReinvestmentController.SweptNotBacked.selector);
    vm.prank(admin);
    controller.claimDust(alice);
  }

  function test_claimDust_revertsWith_NoDustWithdrawalInProcess_principalWithdrawal() public {
    vm.prank(admin);
    controller.claimDust(alice);

    _reinvest(INVESTED);
    _pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.roll(block.number + WITHDRAWAL_DELAY);

    assertEq(controller.getPendingDust(), 0);
    assertGt(wallet.withdrawingBalance(address(usdc), address(controller)), 0);

    vm.expectRevert(IReinvestmentController.NoDustWithdrawalInProcess.selector);
    vm.prank(admin);
    controller.claimDust(alice);
  }

  function test_claimDust_revertsWith_AccessControlUnauthorizedAccount_keeper() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        keeper,
        adminRole
      )
    );
    vm.prank(keeper);
    controller.claimDust(alice);
  }

  function test_claimDust_revertsWith_AccessControlUnauthorizedAccount_pauser() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        pauser,
        adminRole
      )
    );
    vm.prank(pauser);
    controller.claimDust(alice);
  }

  function test_claimDust_revertsWith_InvalidZeroAddress() public {
    vm.expectRevert(IReinvestmentController.InvalidZeroAddress.selector);
    vm.prank(admin);
    controller.claimDust(address(0));
  }

  function test_claimDust_revertsWith_InvalidRecipient() public {
    vm.expectRevert(IReinvestmentController.InvalidRecipient.selector);
    vm.prank(admin);
    controller.claimDust(keeper);
  }

  function test_claimDust_revertsWith_NoDustWithdrawalInProcess() public {
    vm.prank(admin);
    controller.claimDust(alice);

    vm.expectRevert(IReinvestmentController.NoDustWithdrawalInProcess.selector);
    vm.prank(admin);
    controller.claimDust(alice);
  }

  function test_claimDust_revertsWith_ExpectedPause() public {
    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
    vm.prank(admin);
    controller.claimDust(alice);
  }

  /// @dev Unpauses and invests again, leaving the controller unpaused
  function _reinvest(uint256 amount) internal {
    _unpause();
    vm.warp(block.timestamp + INVEST_MIN_DELAY);
    _invest(amount);
  }

  /// @dev Clears the dust queued in setUp, invests again and divests everything with the burn
  /// deferred: the mint lands and {divest} lowers swept to zero, but the Gateway balance is
  /// untouched until {_burnDivested}. Leaves the controller paused
  function _divestAllWithDeferredBurn() internal {
    vm.prank(admin);
    controller.claimDust(alice);
    _reinvest(INVESTED);
    _setMaxFee(CONFIGURED_FEE);

    vm.mockCall(address(minter), abi.encodeWithSelector(minter.gatewayMint.selector), '');
    usdc.mint(address(controller), DIVESTED);

    usdc.mint(keeper, CONFIGURED_FEE);
    vm.startPrank(keeper);
    usdc.approve(address(controller), CONFIGURED_FEE);
    controller.divest(DIVESTED, _encodeAttestation(_defaultTransferSpec(DIVESTED)), hex'1234');
    vm.stopPrank();

    vm.clearMockedCalls();
    _pause();

    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), INVESTED);
  }

  function _burnDivested(uint256 fee) internal {
    vm.prank(address(minter));
    wallet.gatewayBurn(address(usdc), address(controller), DIVESTED, fee);
  }
}

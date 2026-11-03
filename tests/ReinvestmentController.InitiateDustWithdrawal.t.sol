// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerInitiateDustWithdrawalTest is ReinvestmentControllerTestBase {
  uint256 internal constant INVESTED = 400_000e6;
  uint256 internal constant DUST = 1_000e6;

  function setUp() public override {
    super.setUp();

    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
    vm.prank(admin);
    controller.grantRole(adminRole, alice);

    _invest(INVESTED);
    _donate(DUST);
    _divest(INVESTED);
    _pause();
  }

  function test_initiateDustWithdrawal() public {
    vm.expectEmit(address(controller));
    emit IReinvestmentController.DustWithdrawalInitiated(DUST);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(controller.getPendingDust(), DUST);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), DUST);
    assertEq(
      wallet.withdrawalBlock(address(usdc), address(controller)),
      block.number + WITHDRAWAL_DELAY
    );
    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
    assertEq(usdc.balanceOf(address(controller)), 0);
    assertEq(usdc.balanceOf(address(wallet)), DUST);
  }

  function test_initiateDustWithdrawal(uint256 dust) public {
    dust = bound(dust, 1, 1_000_000e6);

    _donate(dust);

    vm.expectEmit(address(controller));
    emit IReinvestmentController.DustWithdrawalInitiated(DUST + dust);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), DUST + dust);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(hub.getAssetSwept(assetId), 0);
  }

  function test_initiateDustWithdrawal_blocksUnpause() public {
    vm.prank(admin);
    controller.initiateDustWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.unpause();
  }

  function test_initiateDustWithdrawal_revertsWith_AccessControlUnauthorizedAccount_keeper()
    public
  {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        keeper,
        adminRole
      )
    );
    vm.prank(keeper);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_AccessControlUnauthorizedAccount_pauser()
    public
  {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        pauser,
        adminRole
      )
    );
    vm.prank(pauser);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_ExpectedPause() public {
    vm.prank(admin);
    controller.unpause();

    vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_WithdrawalInProcess() public {
    vm.prank(admin);
    controller.initiateDustWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_WithdrawalInProcess_principalWithdrawal()
    public
  {
    _reinvest(INVESTED);
    _pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_SweptNotZero() public {
    _reinvest(INVESTED);
    _pause();

    vm.expectRevert(IReinvestmentController.SweptNotZero.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_SweptNotZero(uint256 remaining) public {
    remaining = bound(remaining, 1, INVESTED - 1);

    _reinvest(INVESTED);
    _divest(INVESTED - remaining);
    _pause();

    vm.expectRevert(IReinvestmentController.SweptNotZero.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  function test_initiateDustWithdrawal_revertsWith_NoDust() public {
    vm.prank(admin);
    controller.initiateDustWithdrawal();

    vm.roll(block.number + WITHDRAWAL_DELAY);

    vm.prank(admin);
    controller.claimDust(alice);

    vm.expectRevert(IReinvestmentController.NoDust.selector);
    vm.prank(admin);
    controller.initiateDustWithdrawal();
  }

  /// @dev Unpauses and invests again, leaving the controller unpaused
  function _reinvest(uint256 amount) internal {
    _unpause();
    vm.warp(block.timestamp + INVEST_MIN_DELAY);
    _invest(amount);
  }
}

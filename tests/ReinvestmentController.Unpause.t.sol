// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerUnpauseTest is ReinvestmentControllerTestBase {
  function setUp() public override {
    super.setUp();

    _pause();
  }

  function test_unpause() public {
    vm.expectEmit(address(controller));
    emit PausableUpgradeable.Unpaused(admin);

    vm.prank(admin);
    controller.unpause();

    assertFalse(controller.paused());
  }

  function test_unpause_restoresInvest() public {
    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.invest(1_000e6);

    assertEq(controller.getInvestedAmount(), 1_000e6);
  }

  /// @dev After a full divest, the pending burn takes the whole queued dust withdrawal, leaving
  /// nothing for {claimDust} to complete
  function test_unpause_clearsPendingDust() public {
    _unpause();
    _invest(1_000e6);
    _divestWithDeferredBurn(1_000e6);
    _pause();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(1_000e6, 0);

    assertEq(controller.getPendingDust(), 1_000e6);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);

    vm.prank(admin);
    controller.unpause();

    assertEq(controller.getPendingDust(), 0);
  }

  function test_unpause_revertsWith_AccessControlUnauthorizedAccount_pauserCannotUndoItsOwnHalt()
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
    controller.unpause();
  }

  function test_unpause_revertsWith_AccessControlUnauthorizedAccount() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        alice,
        adminRole
      )
    );
    vm.prank(alice);
    controller.unpause();
  }

  function test_unpause_revertsWith_ExpectedPause_notPaused() public {
    vm.prank(admin);
    controller.unpause();

    vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
    vm.prank(admin);
    controller.unpause();
  }

  function test_unpause_revertsWith_WithdrawalInProcess() public {
    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.invest(1_000e6);

    vm.prank(pauser);
    controller.pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.unpause();
  }

  function test_unpause_afterWithdrawalCompletes() public {
    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.invest(1_000e6);

    vm.prank(pauser);
    controller.pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.roll(block.number + WITHDRAWAL_DELAY);

    vm.prank(admin);
    controller.withdraw();

    vm.prank(admin);
    controller.unpause();

    assertFalse(controller.paused());
  }
}

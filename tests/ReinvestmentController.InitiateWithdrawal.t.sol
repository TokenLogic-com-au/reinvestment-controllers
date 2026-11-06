// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerInitiateWithdrawalTest is ReinvestmentControllerTestBase {
  uint256 internal constant INVESTED = 400_000e6;
  uint256 internal constant DUST = 1_000e6;

  function setUp() public override {
    super.setUp();

    _invest(INVESTED);
    _pause();
  }

  function test_initiateWithdrawal() public {
    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalInitiated(INVESTED);

    vm.prank(admin);
    controller.initiateWithdrawal();

    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), INVESTED);
    assertEq(
      wallet.withdrawalBlock(address(usdc), address(controller)),
      block.number + WITHDRAWAL_DELAY
    );
    assertEq(hub.getAssetSwept(assetId), INVESTED);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED - INVESTED);
    assertEq(usdc.balanceOf(address(controller)), 0);
    assertEq(usdc.balanceOf(address(wallet)), INVESTED);
  }

  /// @dev A debit the controller did not account for, such as a batch adjustment, can take a whole
  /// queued dust withdrawal while swept is above zero
  function test_initiateWithdrawal_clearsPendingDust() public {
    _donate(DUST);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(INVESTED + DUST, 0);
    _donate(DUST);

    vm.prank(admin);
    controller.initiateWithdrawal();

    assertEq(controller.getPendingDust(), 0);
  }

  function test_initiateWithdrawal(uint256 burned) public {
    burned = bound(burned, 1, INVESTED - 1);

    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.divest(burned, _encodeAttestation(_defaultTransferSpec(burned)), hex'1234');

    vm.prank(pauser);
    controller.pause();

    uint256 remaining = wallet.availableBalance(address(usdc), address(controller));

    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalInitiated(remaining);

    vm.prank(admin);
    controller.initiateWithdrawal();

    assertEq(remaining, INVESTED - burned);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), remaining);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
  }

  function test_initiateWithdrawal_afterPartialDivest() public {
    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.divest(100_000e6, _encodeAttestation(_defaultTransferSpec(100_000e6)), hex'1234');

    vm.prank(pauser);
    controller.pause();

    vm.prank(admin);
    controller.initiateWithdrawal();

    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), INVESTED - 100_000e6);
    assertEq(hub.getAssetSwept(assetId), INVESTED - 100_000e6);
  }

  function test_initiateWithdrawal_blocksUnpause() public {
    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.unpause();
  }

  function test_initiateWithdrawal_revertsWith_AccessControlUnauthorizedAccount_keeper() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        keeper,
        adminRole
      )
    );
    vm.prank(keeper);
    controller.initiateWithdrawal();
  }

  function test_initiateWithdrawal_revertsWith_AccessControlUnauthorizedAccount_pauser() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        pauser,
        adminRole
      )
    );
    vm.prank(pauser);
    controller.initiateWithdrawal();
  }

  function test_initiateWithdrawal_revertsWith_ExpectedPause() public {
    vm.prank(admin);
    controller.unpause();

    vm.expectRevert(PausableUpgradeable.ExpectedPause.selector);
    vm.prank(admin);
    controller.initiateWithdrawal();
  }

  function test_initiateWithdrawal_revertsWith_WithdrawalInProcess() public {
    vm.prank(admin);
    controller.initiateWithdrawal();

    vm.expectRevert(IReinvestmentController.WithdrawalInProcess.selector);
    vm.prank(admin);
    controller.initiateWithdrawal();
  }

  function test_initiateWithdrawal_revertsWith_InvalidAmount_noAvailableBalance() public {
    vm.prank(admin);
    controller.unpause();

    vm.prank(keeper);
    controller.divest(INVESTED, _encodeAttestation(_defaultTransferSpec(INVESTED)), hex'1234');

    vm.prank(pauser);
    controller.pause();

    vm.expectRevert(IReinvestmentController.InvalidAmount.selector);
    vm.prank(admin);
    controller.initiateWithdrawal();
  }

  function test_initiateWithdrawal_donationExceedsSwept() public {
    usdc.mint(alice, 1);

    vm.startPrank(alice);
    usdc.approve(address(wallet), 1);
    wallet.depositFor(address(usdc), address(controller), 1);
    vm.stopPrank();

    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalInitiated(INVESTED);

    vm.prank(admin);
    controller.initiateWithdrawal();

    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), INVESTED);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 1);

    vm.roll(block.number + WITHDRAWAL_DELAY);

    vm.prank(admin);
    controller.withdraw();

    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), 1);
  }
}

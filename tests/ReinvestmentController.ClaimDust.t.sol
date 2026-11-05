// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerClaimDustTest is ReinvestmentControllerTestBase {
  uint256 internal constant INVESTED = 400_000e6;
  uint256 internal constant DUST = 1_000e6;
  uint256 internal constant BURNED = 100_000e6;
  uint256 internal constant DIVESTED = 100_000e6;
  uint256 internal constant DIVESTED_MOST = 300_000e6;
  uint256 internal constant CONFIGURED_FEE = 1e6;
  uint256 internal constant CHARGED_FEE = 0.8e6;

  function setUp() public override {
    super.setUp();

    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
    vm.prank(admin);
    controller.grantRole(adminRole, alice);

    _invest(INVESTED);
    _donate(DUST);
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
    assertEq(usdc.balanceOf(address(wallet)), INVESTED);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), INVESTED);
    assertEq(hub.getAssetSwept(assetId), INVESTED);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED - INVESTED);
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

  /// @dev {divest} lowers swept at mint while the Gateway balance only drops when Circle burns, so
  /// a dust withdrawal queued in between includes money already owed. Once the burn lands, the
  /// claim returns the whole withdrawal to the Hub, and a second round collects the real dust
  function test_claimDust_pendingBurnReturnsWithdrawalToHub() public {
    _prepareDeferredBurn(DIVESTED);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(controller.getPendingDust(), DIVESTED + CONFIGURED_FEE);

    _burn(DIVESTED, CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 sweptBefore = hub.getAssetSwept(assetId);
    uint256 liquidityBefore = hub.getAssetLiquidity(assetId);
    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalCompleted(DIVESTED + CONFIGURED_FEE);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(usdc.balanceOf(alice), aliceBefore);
    assertEq(controller.getPendingDust(), 0);
    assertEq(hub.getAssetSwept(assetId), sweptBefore - DIVESTED - CONFIGURED_FEE);
    assertEq(hub.getAssetLiquidity(assetId), liquidityBefore + DIVESTED + CONFIGURED_FEE);
    assertEq(
      wallet.availableBalance(address(usdc), address(controller)),
      hub.getAssetSwept(assetId) + CONFIGURED_FEE - CHARGED_FEE
    );
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(usdc.balanceOf(address(controller)), 0);

    vm.prank(admin);
    controller.initiateDustWithdrawal();
    vm.roll(block.number + WITHDRAWAL_DELAY);
    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(usdc.balanceOf(alice) - aliceBefore, CONFIGURED_FEE - CHARGED_FEE);
    assertEq(
      wallet.availableBalance(address(usdc), address(controller)),
      hub.getAssetSwept(assetId)
    );
  }

  /// @dev A pending burn larger than the available balance spills into the queued withdrawal,
  /// leaving it above swept. The claim returns all of swept to the Hub and deposits the excess
  /// back into the Gateway
  function test_claimDust_pendingBurnSpillingIntoQueueRedepositsExcess() public {
    _prepareDeferredBurn(DIVESTED_MOST);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(DIVESTED_MOST, CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 swept = hub.getAssetSwept(assetId);
    uint256 aliceBefore = usdc.balanceOf(alice);

    assertEq(wallet.availableBalance(address(usdc), address(controller)), 0);
    assertGt(wallet.withdrawingBalance(address(usdc), address(controller)), swept);

    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalCompleted(swept);

    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertEq(usdc.balanceOf(alice), aliceBefore);
    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
    assertEq(
      wallet.availableBalance(address(usdc), address(controller)),
      CONFIGURED_FEE - CHARGED_FEE
    );
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(usdc.balanceOf(address(controller)), 0);
  }

  /// @dev With two burns pending, the first landing during the withdrawal delay shows the queue
  /// holds money owed to Circle. Returning all of it to the Hub keeps swept backed when the
  /// second burn lands after the claim
  function test_claimDust_secondPendingBurnStaysBacked() public {
    _prepareDeferredBurns(DIVESTED, DIVESTED / 2);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(DIVESTED, CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    _burn(DIVESTED / 2, CHARGED_FEE);

    assertEq(usdc.balanceOf(alice), aliceBefore);
    assertEq(
      wallet.availableBalance(address(usdc), address(controller)),
      hub.getAssetSwept(assetId) + 2 * (CONFIGURED_FEE - CHARGED_FEE)
    );
  }

  /// @dev As above, but the first burn spills into the queue, so swept is fully repaid and the
  /// excess deposited back into the Gateway. That deposit is what the second burn takes, even
  /// after the controller has invested again
  function test_claimDust_secondPendingBurnAfterSpillIsCoveredByRedeposit() public {
    _prepareDeferredBurns(DIVESTED_MOST, DIVESTED / 2);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(DIVESTED_MOST, CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(hub.getAssetSwept(assetId), 0);

    _unpause();
    vm.warp(block.timestamp + INVEST_MIN_DELAY);
    _invest(INVESTED);

    _burn(DIVESTED / 2, CHARGED_FEE);

    assertEq(
      wallet.availableBalance(address(usdc), address(controller)),
      INVESTED + 2 * (CONFIGURED_FEE - CHARGED_FEE)
    );
    assertEq(hub.getAssetSwept(assetId), INVESTED);
  }

  /// @dev A donation during the withdrawal delay can cover a landed burn, keeping available at
  /// swept. The claim then pays out the whole queue, and swept stays backed by the donation
  function test_claimDust_donationCoveringLandedBurnIsPaidOut() public {
    _prepareDeferredBurn(DIVESTED);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _donate(DIVESTED + CHARGED_FEE);
    _burn(DIVESTED, CHARGED_FEE);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 sweptBefore = hub.getAssetSwept(assetId);
    uint256 aliceBefore = usdc.balanceOf(alice);

    assertEq(wallet.availableBalance(address(usdc), address(controller)), sweptBefore);

    vm.expectEmit(address(controller));
    emit IReinvestmentController.ClaimedDust(alice, DIVESTED + CONFIGURED_FEE);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(usdc.balanceOf(alice) - aliceBefore, DIVESTED + CONFIGURED_FEE);
    assertEq(hub.getAssetSwept(assetId), sweptBefore);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), sweptBefore);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
  }

  function test_claimDust(uint256 divested, uint256 chargedFee, uint256 donated) public {
    divested = bound(divested, 1, INVESTED - CONFIGURED_FEE);
    chargedFee = bound(chargedFee, 0, CONFIGURED_FEE);
    donated = bound(donated, 0, DUST);

    _prepareDeferredBurn(divested);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _donate(donated);
    _burn(divested, chargedFee);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    uint256 available = wallet.availableBalance(address(usdc), address(controller));
    uint256 swept = hub.getAssetSwept(assetId);

    assertGe(available, swept);
    assertEq(
      usdc.balanceOf(alice) - aliceBefore + available - swept,
      CONFIGURED_FEE - chargedFee + donated
    );
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(usdc.balanceOf(address(controller)), 0);
  }

  function test_claimDust_secondBurnAfterClaim(
    uint256 first,
    uint256 second,
    uint256 chargedFee
  ) public {
    first = bound(first, 1, INVESTED / 2);
    second = bound(second, 1, INVESTED / 2 - 2 * CONFIGURED_FEE);
    chargedFee = bound(chargedFee, 0, CONFIGURED_FEE);

    _prepareDeferredBurns(first, second);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(first, chargedFee);
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    _burn(second, chargedFee);

    uint256 available = wallet.availableBalance(address(usdc), address(controller));
    uint256 swept = hub.getAssetSwept(assetId);

    assertEq(usdc.balanceOf(alice), aliceBefore);
    assertGe(available, swept);
    assertEq(available - swept, 2 * (CONFIGURED_FEE - chargedFee));
    assertEq(usdc.balanceOf(address(controller)), 0);
  }

  /// @dev A debit {divest} never accounted for also leaves available below swept, so the
  /// withdrawal is returned to the Hub
  function test_claimDust_unaccountedDebitReturnsWithdrawalToHub() public {
    _burn(BURNED, 0);

    uint256 liquidityBefore = hub.getAssetLiquidity(assetId);

    vm.expectEmit(address(controller));
    emit IReinvestmentController.WithdrawalCompleted(DUST);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(usdc.balanceOf(alice), 0);
    assertEq(hub.getAssetSwept(assetId), INVESTED - DUST);
    assertEq(hub.getAssetLiquidity(assetId), liquidityBefore + DUST);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), INVESTED - BURNED);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
  }

  /// @dev A burn can drain a queued dust withdrawal that holds no real dust, leaving `pendingDust`
  /// set. A later principal withdrawal finalized through {claimDust} leaves available below swept,
  /// so it is returned to the Hub as {withdraw} would
  function test_claimDust_stalePendingDustFinalizesAsWithdraw() public {
    _prepareDeferredBurn(INVESTED - CONFIGURED_FEE);

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _burn(INVESTED - CONFIGURED_FEE, CONFIGURED_FEE);

    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
    assertEq(controller.getPendingDust(), INVESTED);

    _unpause();
    vm.warp(block.timestamp + INVEST_MIN_DELAY);
    _invest(INVESTED);
    _donate(DUST);
    _pause();

    vm.prank(admin);
    controller.initiateWithdrawal();
    vm.roll(block.number + WITHDRAWAL_DELAY);

    uint256 aliceBefore = usdc.balanceOf(alice);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(usdc.balanceOf(alice), aliceBefore);
    assertEq(hub.getAssetSwept(assetId), 0);
    assertEq(hub.getAssetLiquidity(assetId), SUPPLIED);
    assertEq(wallet.availableBalance(address(usdc), address(controller)), DUST);
    assertEq(wallet.withdrawingBalance(address(usdc), address(controller)), 0);
  }

  function test_claimDust_revertsWith_NoDustWithdrawalInProcess_principalWithdrawal() public {
    vm.startPrank(admin);
    controller.claimDust(alice);
    controller.initiateWithdrawal();
    vm.stopPrank();

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

  /// @dev Clears the dust queued in setUp and divests `amount` with the burn deferred. Leaves the
  /// controller paused
  function _prepareDeferredBurn(uint256 amount) internal {
    vm.prank(admin);
    controller.claimDust(alice);
    _unpause();
    _setMaxFee(CONFIGURED_FEE);
    _divestWithDeferredBurn(amount);
    _pause();
  }

  /// @dev As {_prepareDeferredBurn}, with two divests whose burns are both deferred
  function _prepareDeferredBurns(uint256 first, uint256 second) internal {
    vm.prank(admin);
    controller.claimDust(alice);
    _unpause();
    _setMaxFee(CONFIGURED_FEE);
    _divestWithDeferredBurn(first);
    _divestWithDeferredBurn(second);
    _pause();
  }
}

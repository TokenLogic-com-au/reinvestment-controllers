// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/interfaces/IERC20.sol';
import {PausableUpgradeable} from '@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol';

import {IGatewayWallet} from '../src/interfaces/IGatewayWallet.sol';
import {IReinvestmentController} from '../src/interfaces/IReinvestmentController.sol';

import {
  IBurns,
  ITransferSpecHashes,
  ReinvestmentControllerForkBase
} from './ReinvestmentController.ForkBase.t.sol';

/// @dev Each test authorizes through the TEE model, changes state, then settles the mint and the
/// burn without the controller's ERC-1271 check running again.
contract ReinvestmentControllerForkTeeTest is ReinvestmentControllerForkBase {
  uint256 internal constant CHARGED_FEE = 0.4e6;

  function test_teeBurn() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    _expectNoSignatureRecheck();

    _settle(auth, keeper, MAX_FEE);

    assertEq(_swept(), 0);
    assertEq(_available(), 0);
  }

  function test_teeBurn_revertsWith_InvalidIntentSourceSignerAtIndex_unregisteredSigner() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');
    (address impostor, uint256 impostorPrivateKey) = makeAddrAndKey('impostor');

    vm.expectRevert(
      abi.encodeWithSelector(
        IBurns.InvalidIntentSourceSignerAtIndex.selector,
        0,
        address(controller),
        impostor
      )
    );
    _gatewayBurn(auth.intent, _sign(impostorPrivateKey, auth.digest), MAX_FEE);
  }

  /// @dev An authorized intent cannot be minted while paused, and Circle does not burn what has not
  /// been minted, so the balance stays intact until the intent settles after unpause
  function test_teeBurn_afterPause_unmintedIsHeldUntilUnpause() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    vm.prank(admin);
    controller.pause();

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    controller.isValidSignature(auth.digest, auth.keeperSignature);

    _expectNoSignatureRecheck();

    vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
    _mint(auth, keeper);

    assertEq(_swept(), invested);
    assertEq(_available(), invested);

    vm.prank(admin);
    controller.unpause();

    _settle(auth, keeper, MAX_FEE);

    assertEq(_swept(), 0);
    assertEq(_available(), 0);
  }

  /// @dev A burn whose mint finalized before the pause still lands, settling what {divest} recorded
  function test_teeBurn_afterPause_mintedStillBurns() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    _expectNoSignatureRecheck();

    _mint(auth, keeper);

    vm.prank(admin);
    controller.pause();

    assertEq(_swept(), 0);
    assertEq(_available(), invested);

    _teeBurn(auth, MAX_FEE);

    assertEq(_swept(), 0);
    assertEq(_available(), 0);
  }

  function test_teeBurn_afterKeeperRevoked() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    bytes32 keeperRole = controller.KEEPER_ROLE();
    vm.prank(admin);
    controller.revokeRole(keeperRole, keeper);

    deal(USDC, admin, MAX_FEE);
    vm.prank(admin);
    IERC20(USDC).approve(address(controller), MAX_FEE);

    vm.expectRevert(IReinvestmentController.InvalidSignature.selector);
    controller.isValidSignature(auth.digest, auth.keeperSignature);

    _expectNoSignatureRecheck();

    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector,
        keeper,
        keeperRole
      )
    );
    _mint(auth, keeper);

    _settle(auth, admin, MAX_FEE);

    assertEq(_swept(), 0);
    assertEq(_available(), 0);
  }

  /// @dev The documented hazard: Circle charges the fee the intent was authorized under, while
  /// {divest} pre-pays the lowered cap, leaving `swept` overstated by the difference
  function test_teeBurn_afterMaxFeeLowered() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested / 2, 'a');
    uint256 loweredFee = MAX_FEE / 2;

    vm.startPrank(admin);
    controller.pause();
    controller.setMaxFee(loweredFee);
    controller.unpause();
    vm.stopPrank();

    _expectNoSignatureRecheck();

    _settle(auth, keeper, MAX_FEE);

    assertEq(_swept(), invested - auth.amount - loweredFee);
    assertEq(_available(), invested - auth.amount - MAX_FEE);
    assertEq(_swept() - _available(), MAX_FEE - loweredFee);
  }

  function test_teeBurn_afterMaxFeeRaised() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested / 2, 'a');
    uint256 raisedFee = MAX_FEE * 2;

    vm.startPrank(admin);
    controller.pause();
    controller.setMaxFee(raisedFee);
    controller.unpause();
    vm.stopPrank();

    _expectNoSignatureRecheck();

    _settle(auth, keeper, MAX_FEE);

    assertEq(_swept(), invested - auth.amount - raisedFee);
    assertEq(_available(), invested - auth.amount - MAX_FEE);
    assertEq(_available() - _swept(), raisedFee - MAX_FEE);
  }

  /// @dev A mint finalized but not yet burned when the withdrawal starts. Capping the withdrawal at
  /// `swept` leaves exactly the pending burn behind in the available balance
  function test_teeBurn_afterInitiateWithdrawal() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested / 2, 'a');
    uint256 remaining = invested - auth.amount - MAX_FEE;

    _expectNoSignatureRecheck();

    _mint(auth, keeper);

    vm.startPrank(admin);
    controller.pause();
    controller.initiateWithdrawal();
    vm.stopPrank();

    assertEq(_withdrawing(), remaining);
    assertEq(_available(), auth.amount + MAX_FEE);

    _teeBurn(auth, MAX_FEE);

    assertEq(_available(), 0);
    assertEq(_withdrawing(), remaining);

    vm.roll(block.number + IGatewayWallet(GATEWAY_WALLET).withdrawalDelay());
    vm.prank(admin);
    controller.withdraw();

    assertEq(_withdrawing(), 0);
    assertEq(_swept(), 0);
  }

  /// @dev Two requests authorized against the same state, whose combined value fits the balance
  function test_teeBurn_concurrentAuthorizationsWithinBalance() public {
    uint256 invested = _investAll();
    uint256 amount = invested / 2 - MAX_FEE;
    Authorization memory first = _authorize(amount, 'first');
    Authorization memory second = _authorize(amount, 'second');

    _expectNoSignatureRecheck();

    _mint(first, keeper);
    _mint(second, keeper);
    _teeBurn(first, MAX_FEE);
    _teeBurn(second, MAX_FEE);

    assertEq(_swept(), invested - 2 * (amount + MAX_FEE));
    assertEq(_available(), _swept());
  }

  /// @dev Each request passes {isValidSignature} on its own, but together they exceed the balance.
  /// {divest} refuses the second mint, and Circle does not burn an intent that was never minted,
  /// so `swept` and the Gateway balance stay equal
  function test_teeBurn_concurrentAuthorizationsOverCommit() public {
    uint256 invested = _investAll();
    uint256 amount = (invested * 6) / 10;
    Authorization memory first = _authorize(amount, 'first');
    Authorization memory second = _authorize(amount, 'second');
    uint256 remaining = invested - amount - MAX_FEE;

    _expectNoSignatureRecheck();

    _settle(first, keeper, MAX_FEE);

    vm.expectRevert(IReinvestmentController.InsufficientLiquidity.selector);
    _mint(second, keeper);

    assertEq(_swept(), remaining);
    assertEq(_available(), remaining);
  }

  /// @dev The refused mint's attestation stays valid, so once a later invest restores enough
  /// `swept` it mints, Circle burns it, and the books stay exact
  function test_teeBurn_concurrentAuthorizationsOverCommit_settlesAfterReinvest() public {
    uint256 invested = _investAll();
    uint256 amount = (invested * 6) / 10;
    Authorization memory first = _authorize(amount, 'first');
    Authorization memory second = _authorize(amount, 'second');
    uint256 remaining = invested - amount - MAX_FEE;

    _expectNoSignatureRecheck();

    _settle(first, keeper, MAX_FEE);

    vm.expectRevert(IReinvestmentController.InsufficientLiquidity.selector);
    _mint(second, keeper);

    vm.warp(block.timestamp + INVEST_MIN_DELAY + 1);
    uint256 reinvested = _investAll();
    assertGe(remaining + reinvested, amount + MAX_FEE);

    _settle(second, keeper, MAX_FEE);

    assertEq(_swept(), remaining + reinvested - amount - MAX_FEE);
    assertEq(_available(), _swept());
  }

  function test_teeBurn_revertsWith_TransferSpecHashUsed_duplicateSubmission() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested / 4, 'a');

    _settle(auth, keeper, MAX_FEE);

    vm.expectRevert(
      abi.encodeWithSelector(
        ITransferSpecHashes.TransferSpecHashUsed.selector,
        auth.transferSpecHash
      )
    );
    _teeBurn(auth, MAX_FEE);
  }

  /// @dev {divest} lowers `swept` on the mint while the Gateway balance only drops once Circle
  /// burns, so a dust withdrawal queued in between includes money already owed. A burn larger than
  /// the available balance spills into the queue. The claim repays all of `swept` and deposits the
  /// excess back into the Gateway, where a second round collects it
  function test_claimDust_pendingBurnSpillingIntoQueueRedepositsExcess() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
    vm.prank(admin);
    controller.grantRole(adminRole, alice);

    _queueDustAgainstSpillingBurn();

    vm.expectEmit(address(controller));
    emit IReinvestmentController.Redeposited(MAX_FEE - CHARGED_FEE);

    vm.prank(admin);
    controller.claimDust(alice);

    assertEq(IERC20(USDC).balanceOf(alice), 0);
    assertEq(_swept(), 0);
    assertEq(_available(), MAX_FEE - CHARGED_FEE);
    assertEq(_withdrawing(), 0);
    assertEq(IERC20(USDC).balanceOf(address(controller)), 0);

    vm.prank(admin);
    controller.initiateDustWithdrawal();
    vm.roll(block.number + IGatewayWallet(GATEWAY_WALLET).withdrawalDelay());
    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertEq(IERC20(USDC).balanceOf(alice), MAX_FEE - CHARGED_FEE);
    assertEq(_available(), 0);
    assertEq(_withdrawing(), 0);
  }

  /// @dev A dust withdrawal queued before Circle burns holds the burn's funds. Once the burn
  /// lands, available falls below `swept`, and the claim returns the whole queue to the Hub
  function test_claimDust_pendingBurnReturnsWithdrawalToHub() public {
    bytes32 adminRole = controller.DEFAULT_ADMIN_ROLE();
    vm.prank(admin);
    controller.grantRole(adminRole, alice);

    uint256 invested = _investAll();
    uint256 amount = invested / 4;
    Authorization memory auth = _authorize(amount, 'a');

    _mint(auth, keeper);

    vm.prank(admin);
    controller.pause();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(controller.getPendingDust(), amount + MAX_FEE);
    assertEq(_withdrawing(), amount + MAX_FEE);
    assertEq(_available(), _swept());

    _teeBurn(auth, MAX_FEE);

    assertLt(_available(), _swept());

    vm.roll(block.number + IGatewayWallet(GATEWAY_WALLET).withdrawalDelay());

    vm.prank(admin);
    controller.claimDust(alice);

    vm.prank(admin);
    controller.unpause();

    assertEq(controller.getPendingDust(), 0);
    assertEq(_withdrawing(), 0);
    assertEq(_swept(), _available());
    assertEq(IERC20(USDC).balanceOf(alice), 0);
    assertEq(IERC20(USDC).balanceOf(address(controller)), 0);
  }

  function test_divest_revertsWith_TransferSpecHashUsed_duplicateSubmission() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested / 4, 'a');

    _mint(auth, keeper);

    vm.expectRevert(
      abi.encodeWithSelector(
        ITransferSpecHashes.TransferSpecHashUsed.selector,
        auth.transferSpecHash
      )
    );
    _mint(auth, keeper);
  }

  /// @dev Mints three quarters of the investment, pauses and queues a dust withdrawal before Circle
  /// burns, then burns for less than `MAX_FEE`. The burn exceeds what is left available, so it
  /// spills into the queue and leaves it above `swept`
  function _queueDustAgainstSpillingBurn() internal {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize((invested * 3) / 4, 'a');

    _mint(auth, keeper);

    vm.prank(admin);
    controller.pause();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    _teeBurn(auth, CHARGED_FEE);

    assertEq(_available(), 0);
    assertGt(_withdrawing(), _swept());

    vm.roll(block.number + IGatewayWallet(GATEWAY_WALLET).withdrawalDelay());
  }
}

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

interface IDeposits {
  function depositFor(address token, address depositor, uint256 value) external;
}

/// @dev Each test authorizes through the TEE model, changes state, then settles the mint and the
/// burn without the controller's ERC-1271 check running again.
contract ReinvestmentControllerForkTeeTest is ReinvestmentControllerForkBase {
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
  /// burns. With `swept` above zero, a burn pending against a queued dust withdrawal would drain
  /// the balance backing `swept` first and leave neither {claimDust} nor {withdraw} able to complete
  function test_initiateDustWithdrawal_revertsWith_SweptNotZero_pendingBurn() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize((invested * 3) / 4, 'a');

    _mint(auth, keeper);

    assertGt(_swept(), 0);

    vm.startPrank(admin);
    controller.pause();

    vm.expectRevert(IReinvestmentController.SweptNotZero.selector);
    controller.initiateDustWithdrawal();
    vm.stopPrank();
  }

  /// @dev Once everything is divested, a burn still pending when the dust withdrawal is queued
  /// takes its funds from the withdrawing balance, leaving exactly the fee Circle did not charge
  function test_initiateDustWithdrawal_pendingBurnBelowMaxFee() public {
    uint256 invested = _investAll();
    uint256 actualFee = 4e5;
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    _mint(auth, keeper);

    assertEq(_swept(), 0);

    vm.startPrank(admin);
    controller.pause();
    controller.initiateDustWithdrawal();
    vm.stopPrank();

    assertEq(_withdrawing(), invested);

    _teeBurn(auth, actualFee);

    assertEq(_withdrawing(), MAX_FEE - actualFee);

    _claimDustAndUnpause();

    assertEq(IERC20(USDC).balanceOf(admin), MAX_FEE - actualFee);
  }

  /// @dev A donation made after the dust withdrawal is queued lands in the available balance. The
  /// pending burn drains it first, so it ends up in the withdrawing balance and is paid out
  function test_initiateDustWithdrawal_pendingBurnWithDonatedDust() public {
    uint256 invested = _investAll();
    Authorization memory auth = _authorize(invested - MAX_FEE, 'a');

    _mint(auth, keeper);

    vm.startPrank(admin);
    controller.pause();
    controller.initiateDustWithdrawal();
    vm.stopPrank();

    deal(USDC, alice, 1);
    vm.startPrank(alice);
    IERC20(USDC).approve(GATEWAY_WALLET, 1);
    IDeposits(GATEWAY_WALLET).depositFor(USDC, address(controller), 1);
    vm.stopPrank();

    _teeBurn(auth, MAX_FEE);

    assertEq(_withdrawing(), 1);

    _claimDustAndUnpause();

    assertEq(IERC20(USDC).balanceOf(admin), 1);
  }

  /// @dev Claims the queued dust to the admin after the Gateway's delay and unpauses, asserting
  /// nothing is left at the Gateway and the Hub's claim is still zero
  function _claimDustAndUnpause() internal {
    vm.roll(block.number + IGatewayWallet(GATEWAY_WALLET).withdrawalDelay());

    vm.startPrank(admin);
    controller.claimDust(admin);
    controller.unpause();
    vm.stopPrank();

    assertFalse(controller.paused());
    assertEq(controller.getPendingDust(), 0);
    assertEq(_swept(), 0);
    assertEq(_available(), 0);
    assertEq(_withdrawing(), 0);
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
}

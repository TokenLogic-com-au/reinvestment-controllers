// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.29;

import {ReinvestmentControllerTestBase} from './ReinvestmentController.Base.t.sol';

contract ReinvestmentControllerStorageTest is ReinvestmentControllerTestBase {
  bytes32 internal constant NAMESPACE_SLOT =
    0x65dc087072dd8c0d5c42256b2a3653a05a0be68d693649cbc5ae4d5c285c5d00;

  uint256 internal constant INVEST_MIN_DELAY_OFFSET = 0;
  uint256 internal constant LAST_INVEST_TIMESTAMP_OFFSET = 1;
  uint256 internal constant LIQUID_BUFFER_BPS_OFFSET = 2;
  uint256 internal constant EXPOSURE_CAP_ABS_OFFSET = 3;
  uint256 internal constant EXPOSURE_CAP_BPS_OFFSET = 4;
  uint256 internal constant MAX_FEE_OFFSET = 5;
  uint256 internal constant PENDING_DUST_OFFSET = 6;

  function test_namespaceSlotMatchesTheErc7201Derivation() public pure {
    bytes32 expected = keccak256(
      abi.encode(uint256(keccak256('reinvestment.storage.ReinvestmentController')) - 1)
    ) & ~bytes32(uint256(0xff));

    assertEq(NAMESPACE_SLOT, expected);
    assertEq(uint256(NAMESPACE_SLOT) & 0xff, 0);
  }

  function test_everyFieldLivesAtItsNamespacedSlot() public {
    vm.prank(keeper);
    controller.invest(1_000e6);
    _divest(1_000e6);

    _setMaxFee(1e6);
    _donate(1e6);
    _pause();

    vm.prank(admin);
    controller.initiateDustWithdrawal();

    assertEq(_load(INVEST_MIN_DELAY_OFFSET), controller.getInvestMinDelay());
    assertEq(_load(LAST_INVEST_TIMESTAMP_OFFSET), controller.getLastInvestTimestamp());
    assertEq(_load(LIQUID_BUFFER_BPS_OFFSET), controller.getLiquidBufferBps());
    assertEq(_load(EXPOSURE_CAP_ABS_OFFSET), controller.getExposureCapAbs());
    assertEq(_load(EXPOSURE_CAP_BPS_OFFSET), controller.getExposureCapBps());
    assertEq(_load(MAX_FEE_OFFSET), controller.getMaxFee());
    assertEq(_load(PENDING_DUST_OFFSET), controller.getPendingDust());
  }

  function test_noStateIsWrittenToSequentialSlots() public {
    vm.prank(keeper);
    controller.invest(1_000e6);

    for (uint256 slot = 0; slot < 16; slot++) {
      assertEq(vm.load(address(controller), bytes32(slot)), bytes32(0));
    }
  }

  function test_writesLandInTheNamespaceRatherThanShiftingIt(uint256 investMinDelay_) public {
    investMinDelay_ = bound(investMinDelay_, 1, 3650 days);

    vm.prank(admin);
    controller.setInvestMinDelay(investMinDelay_);

    assertEq(_load(INVEST_MIN_DELAY_OFFSET), investMinDelay_);
  }

  function _load(uint256 offset) internal view returns (uint256) {
    return uint256(vm.load(address(controller), bytes32(uint256(NAMESPACE_SLOT) + offset)));
  }
}

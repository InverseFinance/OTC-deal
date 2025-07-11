// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "src/RepayRewardEscrow.sol";

interface IMinter is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract RepayRewardEscrowTest is Test {
    RepayRewardEscrow public escrow;
    IMinter public dola;
    IMinter public inv;
    IERC4626 public sInv;

    address gov = address(0x926dF14a23BE491164dCF93f4c468A50ef659D5B); // GOV
    address operator = address(0x9D5Df30F475CEA915b1ed4C0CCa59255C897b61B); // TWG

    address user1 = address(0x123);
    address user2 = address(0x456);

    uint256 invAllowance = 3_000_000 ether; // 3 million INV allowance for the repayment contract

    function setUp() public {
        string memory rpcUrl = vm.rpcUrl("mainnet");
        vm.createSelectFork(rpcUrl, 22895952);

        escrow = new RepayRewardEscrow(gov, operator);

        dola = IMinter(address(escrow.DOLA()));
        inv = IMinter(address(escrow.INV()));
        sInv = escrow.sINV();

        vm.startPrank(gov);
        dola.mint(address(user1), 1_000_000 ether); // Mint 1 million DOLA to user1
        dola.mint(address(user2), 2_000_000 ether); // Mint 2 million DOLA to user2
        inv.approve(address(escrow), invAllowance); // Approve escrow contract to pull INV tokens
        inv.mint(gov, invAllowance); // Mint 3 million INV to gov for testing
        escrow.start(); // Start the buy period and set the vesting timestamp
        vm.stopPrank();

        vm.startPrank(operator);
        escrow.setDolaAllocation(user1, 1_000_000 ether); // Set user1's commitment to 1 million DOLA
        escrow.setDolaAllocation(user2, 2_000_000 ether); // Set user2's commitment to 2 million DOLA
        vm.stopPrank();
    }

    function test_buy_2_users() public {
        uint256 user1Commitment = escrow.dolaAllocations(user1);
        uint256 sInvSupplyBefore = sInv.totalSupply();

        vm.startPrank(user1);
        dola.approve(address(escrow), user1Commitment);
        uint256 expectedInvAmount = user1Commitment * 1 ether / escrow.INV_PRICE();
        assertEq(expectedInvAmount, 40_000 ether, "Expected INV amount should be 40,000"); // 1 million DOLA at 25 DOLA/INV
        uint256 expecteSInvVested = sInv.previewDeposit(expectedInvAmount);

        uint256 lsInvAmount = escrow.buy();

        assertEq(lsInvAmount, expecteSInvVested, "lsINV amount should match expected sINV vested amount");
        assertEq(escrow.balanceOf(user1), lsInvAmount, "lsINV balance not correct");
        assertEq(sInv.balanceOf(address(escrow)), lsInvAmount, "sINV balance not correct");
        assertEq(sInv.balanceOf(address(escrow)), sInv.totalSupply() - sInvSupplyBefore, "sINV supply not correct");
        assertEq(dola.balanceOf(address(escrow)), user1Commitment, "DOLA balance not correct");
        assertEq(escrow.dolaAllocations(user1), 0, "User1 commitment not correct");
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Commitment = escrow.dolaAllocations(user2);
        dola.approve(address(escrow), user2Commitment);
        expectedInvAmount = user2Commitment * 1 ether / escrow.INV_PRICE();
        assertEq(expectedInvAmount, 80_000 ether, "Expected INV amount should be 80,000"); // 2 million DOLA at 25 DOLA/INV
        expecteSInvVested = sInv.previewDeposit(expectedInvAmount);

        // User2 buys lsINV shares
        uint256 lsInvAmount2 = escrow.buy();

        assertEq(lsInvAmount2, expecteSInvVested, "lsINV amount should match expected sINV vested amount for user2");
        assertEq(escrow.balanceOf(user2), lsInvAmount2, "lsINV balance not correct for user2");
        assertEq(sInv.balanceOf(address(escrow)), lsInvAmount + lsInvAmount2, "sINV balance not correct for escrow");
        assertEq(sInv.totalSupply(), sInvSupplyBefore + lsInvAmount + lsInvAmount2, "sINV total supply not correct");
        assertEq(
            dola.balanceOf(address(escrow)), user1Commitment + user2Commitment, "DOLA balance not correct for escrow"
        );
        assertEq(escrow.dolaAllocations(user2), 0, "User2 commitment not reduced correctly");
        vm.stopPrank();

        uint256 dolaBalAfter = dola.balanceOf(address(escrow));
        uint256 capacity = escrow.SALE_HANDLER().getCapacity();
        escrow.sendToSaleHandler(); // Send DOLA to sale handler
        assertEq(dola.balanceOf(address(escrow)), 0, "DOLA balance should be zero after sending to sale handler");
        assertApproxEqAbs(
            (capacity - escrow.SALE_HANDLER().getCapacity()),
            dolaBalAfter,
            1100 ether,
            "DOLA sent to sale handler should match"
        );
    }

    function test_fail_buy_no_allowance() public {
        assertGt(escrow.dolaAllocations(user1), 0, "User1 should have a DOLA allocation");
        vm.prank(user1);
        vm.expectRevert();
        escrow.buy();
        vm.stopPrank();
    }

    function test_fail_buy_if_commitment_not_set() public {
        uint256 dolaAmountIn = 1_000_000 ether;
        vm.prank(gov);
        dola.mint(address(this), dolaAmountIn);

        dola.approve(address(escrow), dolaAmountIn);
        vm.expectRevert("No DOLA allocation set for user");
        escrow.buy();
    }

    function test_fail_redeem_before_redemption_timestamp() public {
        uint256 dolaAmountIn = escrow.dolaAllocations(user1);

        vm.startPrank(user1);
        dola.approve(address(escrow), dolaAmountIn);

        uint256 lsInvAmount = escrow.buy();

        vm.expectRevert("Redemption not started yet");
        escrow.redeem(lsInvAmount); // Should revert as redemption is not started yet
    }

    function test_fail_redeem_if_zero_lsInvAmount() public {
        uint256 dolaAmountIn = escrow.dolaAllocations(user1);

        vm.startPrank(user1);
        dola.approve(address(escrow), dolaAmountIn);

        escrow.buy();

        vm.warp(block.timestamp + 180 days); // Move to redemption time
        vm.expectRevert("lsInvAmount must be greater than zero");
        escrow.redeem(0);
    }

    function test_redeem() public {
        uint256 dolaAmountIn = escrow.dolaAllocations(user1);

        vm.startPrank(user1);
        dola.approve(address(escrow), dolaAmountIn);

        uint256 lsInvAmount = escrow.buy();

        vm.warp(block.timestamp + 180 days); // Move to redemption time

        escrow.redeem(lsInvAmount);

        assertEq(sInv.balanceOf(user1), lsInvAmount, "User should receive sINV tokens");
        assertEq(escrow.balanceOf(user1), 0, "User's shares should be burned");
        assertEq(escrow.balanceOf(address(escrow)), 0, "Escrow contract should have no shares left");
        assertEq(escrow.totalSupply(), 0, "Escrow total supply should be zero");
    }

    function test_redeem_2_users() public {
        test_buy_2_users(); // First buy to set up users
        vm.warp(block.timestamp + 180 days); // Move to redemption time
        uint256 user1Shares = escrow.balanceOf(user1);
        uint256 user2Shares = escrow.balanceOf(user2);

        vm.prank(user1);
        escrow.redeem(user1Shares);
        vm.prank(user2);
        escrow.redeem(user2Shares);

        assertEq(sInv.balanceOf(user1), user1Shares, "User1 should receive INV tokens");
        assertEq(sInv.balanceOf(user2), user2Shares, "User2 should receive INV tokens");
        assertEq(escrow.balanceOf(user1), 0, "User1's shares should be burned");
        assertEq(escrow.balanceOf(user2), 0, "User2's shares should be burned");
        assertEq(escrow.balanceOf(address(escrow)), 0, "Escrow contract should have no shares left");
        assertEq(escrow.totalSupply(), 0, "Escrow total supply should be zero");
    }

    function test_fail_sweep_before_1Year() public {
        vm.startPrank(gov);
        dola.mint(address(escrow), 1_000_000 ether); // Mint some DOLA to escrow contract
        vm.expectRevert("Sweep not allowed yet");
        escrow.sweep(address(inv)); // Should revert as sweep is not allowed yet
        vm.stopPrank();
    }

    function test_fail_sendToSaleHandler_if_no_dola_balance() public {
        vm.expectRevert("No DOLA to send");
        escrow.sendToSaleHandler();
    }

    function test_sweep_succeed_after_1Year() public {
        uint256 dolaBalanceBefore = dola.balanceOf(gov);
        vm.startPrank(gov);
        dola.mint(address(escrow), 1_000_000 ether); // Mint some DOLA to escrow contract
        vm.warp(block.timestamp + 365 days); // Move to sweep time
        escrow.sweep(address(dola)); // Should revert as sweep is not allowed yet
        vm.stopPrank();
        assertEq(dola.balanceOf(gov), dolaBalanceBefore + 1_000_000 ether, "Gov should receive swept DOLA tokens");
    }

    function test_fail_buy_if_not_started() public {
        RepayRewardEscrow newOtc = new RepayRewardEscrow(gov, operator); // Create a new RepayRewardEscrow instance
        vm.prank(operator);
        newOtc.setDolaAllocation(user1, 1_000_000 ether);

        vm.startPrank(user1);
        uint256 dolaAmountIn = 1_000_000 ether;
        dola.approve(address(newOtc), dolaAmountIn);
        vm.expectRevert("Buy period ended or not started");
        newOtc.buy(); // Should revert as buy period is not started
        vm.stopPrank();
    }

    function test_buy_extended_deadline() public {
        vm.warp(block.timestamp + 4 days + 1); // Move time forward to extend the deadline
        vm.startPrank(user1);
        uint256 dolaAmountIn = escrow.dolaAllocations(user1);
        dola.approve(address(escrow), dolaAmountIn);
        vm.expectRevert("Buy period ended or not started");
        escrow.buy(); // Should revert as buy period is not started
        vm.stopPrank();

        // Extend the buy deadline
        vm.prank(operator);
        escrow.extendDeadline(2); // Extend the deadline by 2 days

        vm.prank(user1);
        uint256 shares = escrow.buy(); // Should succeed now
        assertEq(shares, escrow.balanceOf(user1), "Shares should match after extended buy");
        assertEq(escrow.dolaAllocations(user1), 0, "User1 commitment should be zero after buy");
    }

    function test_fail_setDolaAllocation_if_not_operator() public {
        vm.expectRevert("Only operator");
        escrow.setDolaAllocation(user1, 500_000 ether);
    }

    function test_fail_extendDeadline_if_not_operator() public {
        vm.expectRevert("Only operator");
        escrow.extendDeadline(2);
    }

    function test_fail_startBuyPeriod_if_not_governance() public {
        vm.expectRevert("Only governance");
        escrow.start();
    }

    function test_fail_setOperator_if_not_governance() public {
        address newOperator = address(0x789);
        vm.startPrank(user1);
        vm.expectRevert("Only governance");
        escrow.setOperator(newOperator);
    }

    function test_fail_acceptGovernance_if_not_pendingGovernance() public {
        address newGovernance = address(0x789);
        vm.startPrank(gov);
        escrow.setPendingGov(newGovernance);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Only pending gov can accept");
        escrow.acceptGov();
    }

    function test_setOperator() public {
        assertEq(escrow.operator(), operator, "Operator should be set to initial value");
        address newOperator = address(0x789);
        vm.prank(gov);
        escrow.setOperator(newOperator); // Change operator
        assertEq(escrow.operator(), newOperator, "New Operator should be set");
    }
}

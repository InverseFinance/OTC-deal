// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "src/OTCDeal.sol";

interface IMinter is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract OTCDealTest is Test {
    OTCDeal public otc;
    IMinter public dola;
    IMinter public inv;
    IERC4626 public sInv;

    address operator = address(0x926dF14a23BE491164dCF93f4c468A50ef659D5B);

    address user1 = address(0x123);
    address user2 = address(0x456);

    uint256 invAllowance = 3_000_000 ether; // 3 million INV allowance for the repayment contract

    function setUp() public {
        string memory rpcUrl = vm.rpcUrl("mainnet");
        vm.createSelectFork(rpcUrl);

        otc = new OTCDeal(operator);

        dola = IMinter(address(otc.DOLA()));
        inv = IMinter(address(otc.INV()));
        sInv = otc.sINV();

        vm.startPrank(operator);
        dola.mint(address(user1), 1_000_000 ether); // Mint 1 million DOLA to user1
        dola.mint(address(user2), 2_000_000 ether); // Mint 2 million DOLA to user2
        inv.approve(address(otc), invAllowance); // Approve otc contract to pull INV tokens
        otc.setLimit(user1, 1_000_000 ether); // Set user1's limit to 1 million DOLA
        otc.setLimit(user2, 2_000_000 ether); // Set user2's limit to 2 million DOLA
        inv.mint(operator, invAllowance); // Mint 3 million INV to operator for testing
        otc.startBuyPeriod(); // Start the buy period
        vm.stopPrank();
    }

    function test_buy_2_users() public {
        uint256 user1Limit = otc.limits(user1);
        uint256 sInvSupplyBefore = sInv.totalSupply();

        vm.startPrank(user1);
        dola.approve(address(otc), user1Limit);

        uint256 lsInvAmount = otc.buy(user1Limit);

        assertEq(otc.balanceOf(user1), lsInvAmount, "lsINV balance not correct");
        assertEq(sInv.balanceOf(address(otc)), lsInvAmount, "sINV balance not correct");
        assertEq(sInv.balanceOf(address(otc)), sInv.totalSupply() - sInvSupplyBefore, "sINV supply not correct");
        assertEq(dola.balanceOf(address(otc)), user1Limit, "DOLA balance not correct");
        assertEq(otc.limits(user1), 0, "User1 limit not correct");
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Limit = otc.limits(user2);
        dola.approve(address(otc), user2Limit);
        uint256 lsInvAmount2 = otc.buy(user2Limit);

        assertEq(otc.balanceOf(user2), lsInvAmount2, "lsINV balance not correct for user2");
        assertEq(sInv.balanceOf(address(otc)), lsInvAmount + lsInvAmount2, "sINV balance not correct for otc");
        assertEq(sInv.totalSupply(), sInvSupplyBefore + lsInvAmount + lsInvAmount2, "sINV total supply not correct");
        assertEq(dola.balanceOf(address(otc)), user1Limit + user2Limit, "DOLA balance not correct for otc");
        assertEq(otc.limits(user2), 0, "User2 limit not reduced correctly");
        vm.stopPrank();

        uint256 dolaBalAfter = dola.balanceOf(address(otc));
        uint256 capacity = otc.SALE_HANDLER().getCapacity();
        otc.sendToSaleHandler(); // Send DOLA to sale handler
        assertEq(dola.balanceOf(address(otc)), 0, "DOLA balance should be zero after sending to sale handler");
        assertApproxEqAbs(
            (capacity - otc.SALE_HANDLER().getCapacity()),
            dolaBalAfter,
            1000 ether,
            "DOLA sent to sale handler should match"
        );
    }

    function test_fail_buy_exceeding_limit() public {
        uint256 dolaAmountIn = 1_500_000 ether; // User1 tries to buy with 1.5 million DOLA

        vm.startPrank(user1);
        dola.approve(address(otc), dolaAmountIn);

        vm.expectRevert("Can only buy exact limit amount");
        otc.buy(dolaAmountIn); // Should revert as user1's limit is 1 million DOLA
        vm.stopPrank();
    }

    function test_fail_buy_if_limit_not_set() public {
        uint256 dolaAmountIn = 1_000_000 ether;
        vm.prank(operator);
        dola.mint(address(this), dolaAmountIn);

        dola.approve(address(otc), dolaAmountIn);
        vm.expectRevert("Can only buy exact limit amount");
        otc.buy(dolaAmountIn);
    }

    function test_fail_buy_below_limit() public {
        uint256 dolaAmountIn = 500_000 ether; // User1 tries to buy with 1.5 million DOLA

        vm.startPrank(user1);
        dola.approve(address(otc), dolaAmountIn);

        vm.expectRevert("Can only buy exact limit amount");
        otc.buy(dolaAmountIn); // Should revert as user1's limit is 1 million DOLA
        vm.stopPrank();
    }

    function test_fail_buy_with_zero_amount() public {
        vm.startPrank(user1);
        dola.approve(address(otc), type(uint256).max); // Approve maximum amount

        vm.expectRevert("DOLA amount must be greater than zero");
        otc.buy(0); // Should revert as amount is zero
        vm.stopPrank();
    }

    function test_fail_redeem_before_redemption_timestamp() public {
        uint256 dolaAmountIn = 1_000_000 ether;

        vm.startPrank(user1);
        dola.approve(address(otc), dolaAmountIn);

        uint256 lsInvAmount = otc.buy(dolaAmountIn);

        vm.expectRevert("Redemption not started yet");
        otc.redeem(lsInvAmount); // Should revert as redemption is not started yet
    }

    function test_fail_redeem_if_zero_shares() public {
        uint256 dolaAmountIn = 1_000_000 ether;

        vm.startPrank(user1);
        dola.approve(address(otc), dolaAmountIn);

        otc.buy(dolaAmountIn);

        vm.warp(block.timestamp + 180 days); // Move to redemption time
        vm.expectRevert("Shares must be greater than zero");
        otc.redeem(0); // Should revert as redemption is not started yet
    }

    function test_redeem() public {
        uint256 dolaAmountIn = 1_000_000 ether;

        vm.startPrank(user1);
        dola.approve(address(otc), dolaAmountIn);

        uint256 lsInvAmount = otc.buy(dolaAmountIn);

        vm.warp(block.timestamp + 180 days); // Move to redemption time

        uint256 invAmount = otc.redeem(lsInvAmount);

        assertEq(inv.balanceOf(user1), invAmount, "User should receive INV tokens");
        assertEq(otc.balanceOf(user1), 0, "User's shares should be burned");
        assertEq(otc.balanceOf(address(otc)), 0, "OTC contract should have no shares left");
        assertEq(otc.totalSupply(), 0, "OTC total supply should be zero");
    }

    function test_redeem_2_users() public {
        test_buy_2_users(); // First buy to set up users
        vm.warp(block.timestamp + 180 days); // Move to redemption time
        uint256 user1Shares = otc.balanceOf(user1);
        uint256 user2Shares = otc.balanceOf(user2);

        vm.prank(user1);
        uint256 user1InvAmount = otc.redeem(user1Shares);
        vm.prank(user2);
        uint256 user2InvAmount = otc.redeem(user2Shares);

        assertEq(inv.balanceOf(user1), user1InvAmount, "User1 should receive INV tokens");
        assertEq(inv.balanceOf(user2), user2InvAmount, "User2 should receive INV tokens");
        assertEq(otc.balanceOf(user1), 0, "User1's shares should be burned");
        assertEq(otc.balanceOf(user2), 0, "User2's shares should be burned");
        assertEq(otc.balanceOf(address(otc)), 0, "OTC contract should have no shares left");
        assertEq(otc.totalSupply(), 0, "OTC total supply should be zero");
    }

    function test_fail_sweep_before_1Year() public {
        vm.startPrank(operator);
        dola.mint(address(otc), 1_000_000 ether); // Mint some DOLA to otc contract
        vm.expectRevert("Sweep not allowed yet");
        otc.sweep(address(inv)); // Should revert as sweep is not allowed yet
        vm.stopPrank();
    }

    function test_fail_sendToSaleHandler_if_no_dola_balance() public {
        vm.expectRevert("No DOLA to send");
        otc.sendToSaleHandler();
    }

    function test_sweep_succeed_after_1Year() public {
        uint256 dolaBalanceBefore = dola.balanceOf(operator);
        vm.startPrank(operator);
        dola.mint(address(otc), 1_000_000 ether); // Mint some DOLA to otc contract
        vm.warp(block.timestamp + 365 days); // Move to sweep time
        otc.sweep(address(dola)); // Should revert as sweep is not allowed yet
        vm.stopPrank();
        assertEq(
            dola.balanceOf(operator), dolaBalanceBefore + 1_000_000 ether, "Operator should receive swept DOLA tokens"
        );
    }

    function test_fail_buy_if_not_started() public {
        OTCDeal newOtc = new OTCDeal(operator);
        vm.prank(operator);
        newOtc.setLimit(user1, 1_000_000 ether);

        vm.startPrank(user1);
        uint256 dolaAmountIn = 1_000_000 ether;
        dola.approve(address(newOtc), dolaAmountIn);
        vm.expectRevert("Buy period ended or not started");
        newOtc.buy(dolaAmountIn); // Should revert as buy period is not started
        vm.stopPrank();
    }

    function test_buy_extended_deadline() public {
        vm.warp(block.timestamp + 4 days + 1); // Move time forward to extend the deadline
        vm.startPrank(user1);
        uint256 dolaAmountIn = otc.limits(user1);
        dola.approve(address(otc), dolaAmountIn);
        vm.expectRevert("Buy period ended or not started");
        otc.buy(dolaAmountIn); // Should revert as buy period is not started
        vm.stopPrank();

        // Extend the buy deadline
        vm.prank(operator);
        otc.extendDeadline(2); // Extend the deadline by 2 days

        vm.prank(user1);
        uint256 shares = otc.buy(dolaAmountIn); // Should succeed now
        assertEq(shares, otc.balanceOf(user1), "Shares should match after extended buy");
        assertEq(otc.limits(user1), 0, "User1 limit should be zero after buy");
    }

    function test_fail_setLimit_if_not_operator() public {
        vm.expectRevert("Only operator");
        otc.setLimit(user1, 500_000 ether);
    }

    function test_fail_extendDeadline_if_not_operator() public {
        vm.expectRevert("Only operator");
        otc.extendDeadline(2);
    }

    function test_fail_startBuyPeriod_if_not_operator() public {
        vm.expectRevert("Only operator");
        otc.startBuyPeriod();
    }

    function test_fail_setPendingOperator_if_not_operator() public {
        address newOperator = address(0x789);
        vm.startPrank(user1);
        vm.expectRevert("Only operator");
        otc.setPendingOperator(newOperator);
    }

    function test_fail_acceptOperator_if_not_pendingOperator() public {
        address newOperator = address(0x789);
        vm.startPrank(operator);
        otc.setPendingOperator(newOperator);
        vm.stopPrank();

        vm.startPrank(user1);
        vm.expectRevert("Only pending operator can accept");
        otc.acceptOperator();
    }

    function test_setPendingOperator() public {
        assertEq(otc.pendingOperator(), address(0), "Pending operator should be address(0)");
        address newOperator = address(0x789);
        vm.startPrank(operator);
        otc.setPendingOperator(newOperator); // Change operator
        vm.stopPrank();
        assertEq(otc.pendingOperator(), newOperator, "Pending operator should be set");

        vm.prank(newOperator);
        otc.acceptOperator(); // New operator accepts the role
        assertEq(otc.operator(), newOperator, "Operator should be updated to new operator");
        assertEq(otc.pendingOperator(), address(0), "Pending operator should be reset to address(0)");
    }
}

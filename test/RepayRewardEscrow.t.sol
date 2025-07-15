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

interface IsINV is IERC4626 {
    function buyDBR(uint256 exactInvIn, uint256 exactDbrOut, address to) external;
}

interface IAnDola {
    function borrowBalanceStored(address account) external view returns (uint256);
    function totalBorrows() external view returns (uint256);
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
        uint256 invBalanceBefore = inv.balanceOf(gov);
        vm.startPrank(gov);
        inv.mint(address(escrow), 1_000_000 ether); // Mint some DOLA to escrow contract
        vm.warp(block.timestamp + 365 days); // Move to sweep time
        escrow.sweep(address(inv)); // Should revert as sweep is not allowed yet
        vm.stopPrank();
        assertEq(inv.balanceOf(gov), invBalanceBefore + 1_000_000 ether, "Gov should receive swept DOLA tokens");
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

    function test_fail_start_to_be_called_again() public {
        vm.startPrank(gov);
        vm.expectRevert("Already started");
        escrow.start(); // Should revert as start has already been called
    }

    function test_setOperator() public {
        assertEq(escrow.operator(), operator, "Operator should be set to initial value");
        address newOperator = address(0x789);
        vm.prank(gov);
        escrow.setOperator(newOperator); // Change operator
        assertEq(escrow.operator(), newOperator, "New Operator should be set");
    }

    function test_withdrawDOLA() public {
        address receiver = address(0x789);
        assertEq(dola.balanceOf(receiver), 0, "Receiver should have zero DOLA balance initially");
        uint256 dolaAmount = 500_000 ether;
        vm.startPrank(gov);
        dola.mint(address(escrow), dolaAmount); // Mint DOLA to escrow contract

        vm.startPrank(gov);
        escrow.withdrawDOLA(receiver, dolaAmount); // Withdraw DOLA to receiver

        assertEq(dola.balanceOf(receiver), dolaAmount, "Receiver should receive withdrawn DOLA");
    }

    function test_fail_withdrawDOLA_if_not_governance() public {
        address receiver = address(0x789);
        uint256 dolaAmount = 500_000 ether;
        vm.prank(gov);
        dola.mint(address(escrow), dolaAmount); // Mint DOLA to escrow contract

        vm.prank(user1);
        vm.expectRevert("Only governance");
        escrow.withdrawDOLA(receiver, dolaAmount); // Should revert as only governance can withdraw DOLA
    }

    function test_complete_workflow() public {
        escrow = new RepayRewardEscrow(gov, operator);
        uint256 invAmount = 104_000 ether; // 104k INV

        address user1 = address(0x123);
        address user2 = address(0x456);
        address user3 = address(0x789);
        address user4 = address(0x987);
        address user5 = address(0x654);
        address user6 = address(0x321);

        uint256 dolaAmount1 = 800_000 ether; // 800k DOLA for user1
        uint256 dolaAmount2 = 800_000 ether; // 800k DOLA for user2
        uint256 dolaAmount3 = 375_000 ether; // 375k DOLA for user3
        uint256 dolaAmount4 = 200_000 ether; // 200k DOLA for user4
        uint256 dolaAmount5 = 300_000 ether; // 300k DOLA for user5
        uint256 dolaAmount6 = 125_000 ether; // 125k DOLA for user6

        vm.startPrank(gov);
        dola.mint(address(user1), dolaAmount1); // Mint 800k DOLA to user1
        dola.mint(address(user2), dolaAmount2); // Mint 800k DOLA to user2
        dola.mint(address(user3), dolaAmount3); // Mint 375k DOLA to user3
        dola.mint(address(user4), dolaAmount4); // Mint 200k DOLA to user4
        dola.mint(address(user5), dolaAmount5); // Mint 300k DOLA to user5
        dola.mint(address(user6), dolaAmount6); // Mint 125k DOLA to user6

        // Mint INV to governance and approve escrow contract
        uint256 govBalanceBefore = inv.balanceOf(gov);
        inv.mint(gov, invAmount); // Mint 104000 INV to gov
        uint256 govBalanceAfter = inv.balanceOf(gov);
        inv.approve(address(escrow), invAmount); // Approve escrow contract to pull 104000 INV tokens

        vm.stopPrank();

        vm.startPrank(operator);
        escrow.setDolaAllocation(user1, dolaAmount1); // Set user1's commitment to 800k DOLA
        escrow.setDolaAllocation(user2, dolaAmount2); // Set user2's commitment to 800k DOLA
        escrow.setDolaAllocation(user3, dolaAmount3); // Set user3's commitment to 375k DOLA
        escrow.setDolaAllocation(user4, dolaAmount4); // Set user4's commitment to 200k DOLA
        escrow.setDolaAllocation(user5, dolaAmount5); // Set user5's commitment to 300k DOLA
        escrow.setDolaAllocation(user6, dolaAmount6); // Set user6's commitment to 125k DOLA
        vm.stopPrank();

        vm.prank(gov);
        escrow.start(); // Start the buy period and set the vesting timestamp

        // User1 buys lsINV shares
        vm.startPrank(user1);
        dola.approve(address(escrow), dolaAmount1);
        uint256 expectedSInvVested = sInv.previewDeposit(dolaAmount1 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount1 = escrow.buy();
        assertEq(lsInvAmount1, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user1");
        assertEq(escrow.balanceOf(user1), lsInvAmount1, "lsINV balance for user1 should be correct");
        assertEq(sInv.balanceOf(address(escrow)), lsInvAmount1, "sINV balance for escrow should be correct");
        assertEq(escrow.dolaAllocations(user1), 0, "User1 commitment should be zero after buy");
        vm.stopPrank();

        // User2 buys lsINV shares
        vm.startPrank(user2);
        dola.approve(address(escrow), dolaAmount2);
        expectedSInvVested = sInv.previewDeposit(dolaAmount2 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount2 = escrow.buy();
        assertEq(lsInvAmount2, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user2");
        assertEq(escrow.balanceOf(user2), lsInvAmount2, "lsINV balance for user2 should be correct");
        assertEq(
            sInv.balanceOf(address(escrow)), lsInvAmount1 + lsInvAmount2, "sINV balance for escrow should be correct"
        );
        assertEq(escrow.dolaAllocations(user2), 0, "User2 commitment should be zero after buy");
        vm.stopPrank();

        // User3 buys lsINV shares
        vm.startPrank(user3);
        dola.approve(address(escrow), dolaAmount3);
        expectedSInvVested = sInv.previewDeposit(dolaAmount3 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount3 = escrow.buy();
        assertEq(lsInvAmount3, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user3");
        assertEq(escrow.balanceOf(user3), lsInvAmount3, "lsINV balance for user3 should be correct");
        assertEq(
            sInv.balanceOf(address(escrow)),
            lsInvAmount1 + lsInvAmount2 + lsInvAmount3,
            "sINV balance for escrow should be correct"
        );
        assertEq(escrow.dolaAllocations(user3), 0, "User3 commitment should be zero after buy");
        vm.stopPrank();

        // User4 buys lsINV shares
        vm.startPrank(user4);
        dola.approve(address(escrow), dolaAmount4);
        expectedSInvVested = sInv.previewDeposit(dolaAmount4 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount4 = escrow.buy();
        assertEq(lsInvAmount4, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user4");
        assertEq(escrow.balanceOf(user4), lsInvAmount4, "lsINV balance for user4 should be correct");
        assertEq(
            sInv.balanceOf(address(escrow)),
            lsInvAmount1 + lsInvAmount2 + lsInvAmount3 + lsInvAmount4,
            "sINV balance for escrow should be correct"
        );
        assertEq(escrow.dolaAllocations(user4), 0, "User4 commitment should be zero after buy");
        vm.stopPrank();

        // User5 buys lsINV shares
        vm.startPrank(user5);
        dola.approve(address(escrow), dolaAmount5);
        expectedSInvVested = sInv.previewDeposit(dolaAmount5 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount5 = escrow.buy();
        assertEq(lsInvAmount5, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user5");
        assertEq(escrow.balanceOf(user5), lsInvAmount5, "lsINV balance for user5 should be correct");
        assertEq(
            sInv.balanceOf(address(escrow)),
            lsInvAmount1 + lsInvAmount2 + lsInvAmount3 + lsInvAmount4 + lsInvAmount5,
            "sINV balance for escrow should be correct"
        );
        assertEq(escrow.dolaAllocations(user5), 0, "User5 commitment should be zero after buy");
        vm.stopPrank();

        // User6 buys lsINV shares
        vm.startPrank(user6);
        dola.approve(address(escrow), dolaAmount6);
        expectedSInvVested = sInv.previewDeposit(dolaAmount6 * 1 ether / escrow.INV_PRICE());
        uint256 lsInvAmount6 = escrow.buy();
        assertEq(lsInvAmount6, expectedSInvVested, "lsINV amount should match expected sINV vested amount for user6");
        assertEq(escrow.balanceOf(user6), lsInvAmount6, "lsINV balance for user6 should be correct");
        assertEq(
            sInv.balanceOf(address(escrow)),
            lsInvAmount1 + lsInvAmount2 + lsInvAmount3 + lsInvAmount4 + lsInvAmount5 + lsInvAmount6,
            "sINV balance for escrow should be correct"
        );
        assertEq(escrow.dolaAllocations(user6), 0, "User6 commitment should be zero after buy");
        vm.stopPrank();

        assertEq(
            escrow.totalSupply(),
            lsInvAmount1 + lsInvAmount2 + lsInvAmount3 + lsInvAmount4 + lsInvAmount5 + lsInvAmount6,
            "Total sINV supply should match total lsINV shares purchased"
        );
        assertEq(inv.allowance(gov, address(escrow)), 0, "Gov should have reduced INV allowance");

        assertEq(inv.balanceOf(address(escrow)), 0, "Escrow should not have INV");

        assertEq(inv.balanceOf(gov), govBalanceBefore, "Gov should have reduced INV balance after buying lsINV shares");

        assertEq(
            govBalanceAfter - inv.balanceOf(gov),
            invAmount,
            "Gov should have reduced INV balance after buying lsINV shares"
        );

        assertEq(
            dola.balanceOf(address(escrow)),
            dolaAmount1 + dolaAmount2 + dolaAmount3 + dolaAmount4 + dolaAmount5 + dolaAmount6,
            "Escrow should hold total DOLA from all users"
        );
        uint256 totalDolaSent = dolaAmount1 + dolaAmount2 + dolaAmount3 + dolaAmount4 + dolaAmount5 + dolaAmount6;
        // All user have bought lsINV shares, sending to Sale Handler
        IAnDola anDola = IAnDola(0x7Fcb7DAC61eE35b3D4a51117A7c58D53f0a8a670);
        address anDolaBorrower1 = address(0xf508c58ce37ce40a40997C715075172691F92e2D); // User1's anDola borrower
        address anDolaBorrower2 = address(0xeA0c959BBb7476DDD6cD4204bDee82b790AA1562); // User2's anDola borrower
        uint256 anDolaBalance1Before = anDola.borrowBalanceStored(anDolaBorrower1);
        assertGt(anDolaBalance1Before, totalDolaSent, "anDola borrower1 has enough capacity to repay");
        uint256 anDolaBalance2Before = anDola.borrowBalanceStored(anDolaBorrower2);
        uint256 totalBorrowsBefore = anDola.totalBorrows();
        uint256 capacityBefore = escrow.SALE_HANDLER().getCapacity();
        escrow.sendToSaleHandler(); // Send DOLA to sale handler
        uint256 capacityAfter = escrow.SALE_HANDLER().getCapacity();

        assertApproxEqAbs(
            capacityBefore - capacityAfter,
            totalDolaSent,
            1100 ether,
            "DOLA sent to sale handler should match total DOLA from all users"
        );
        assertApproxEqAbs(
            anDola.totalBorrows(),
            totalBorrowsBefore - totalDolaSent,
            1500 ether,
            "Total borrows should decrease total DOLA sent to Sale Handler"
        );
        assertApproxEqAbs(
            anDola.borrowBalanceStored(anDolaBorrower1),
            anDolaBalance1Before - totalDolaSent,
            1000 ether,
            "anDola borrow balance for user1 should match expected reduction"
        );
        // Only repaid user1's borrow balance, user2's borrow balance should not change
        assertApproxEqAbs(
            anDola.borrowBalanceStored(anDolaBorrower2),
            anDolaBalance2Before,
            110 ether,
            "anDola borrow balance should not change"
        );

        vm.warp(block.timestamp + 180 days); // Move to redemption time

        // Add INV rewards by buying DBRs
        address buyer = address(0x123456789);
        vm.prank(gov);
        inv.mint(buyer, 1000 ether); // Mint INV to buyer
        vm.startPrank(buyer);
        inv.approve(address(sInv), 1000 ether); // Approve escrow contract to pull INV tokens
        IsINV(address(sInv)).buyDBR(100 ether, 43000 ether, address(buyer)); // Buy DBR with INV
        vm.warp(block.timestamp + 15 days); // Move to redemption time

        // User1 redeems lsINV shares
        vm.startPrank(user1);
        uint256 user1Shares = escrow.balanceOf(user1);
        console2.log(sInv.previewRedeem(user1Shares), "Expected sINV shares to redeem for 100 INV");
        escrow.redeem(user1Shares);
        assertEq(sInv.balanceOf(user1), user1Shares, "User1 should receive sINV tokens");
        assertEq(escrow.balanceOf(user1), 0, "User1's shares should be burned");
        sInv.redeem(user1Shares, user1, user1); // Redeem sINV shares
        assertGt(inv.balanceOf(user1), 32000 ether, "User1 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        // User2 redeems lsINV shares
        vm.startPrank(user2);
        uint256 user2Shares = escrow.balanceOf(user2);
        escrow.redeem(user2Shares);
        assertEq(sInv.balanceOf(user2), user2Shares, "User2 should receive sINV tokens");
        assertEq(escrow.balanceOf(user2), 0, "User2's shares should be burned");
        sInv.redeem(user2Shares, user2, user2);
        assertGt(inv.balanceOf(user2), 32000 ether, "User2 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        // User3 redeems lsINV shares
        vm.startPrank(user3);
        uint256 user3Shares = escrow.balanceOf(user3);
        escrow.redeem(user3Shares);
        assertEq(sInv.balanceOf(user3), user3Shares, "User3 should receive sINV tokens");
        assertEq(escrow.balanceOf(user3), 0, "User3's shares should be burned");
        sInv.redeem(user3Shares, user3, user3);
        assertGt(inv.balanceOf(user3), 15000 ether, "User3 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        // User4 redeems lsINV shares
        vm.startPrank(user4);
        uint256 user4Shares = escrow.balanceOf(user4);
        escrow.redeem(user4Shares);
        assertEq(sInv.balanceOf(user4), user4Shares, "User4 should receive sINV tokens");
        assertEq(escrow.balanceOf(user4), 0, "User4's shares should be burned");
        sInv.redeem(user4Shares, user4, user4);
        assertGt(inv.balanceOf(user4), 8000 ether, "User4 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        // User5 redeems lsINV shares
        vm.startPrank(user5);
        uint256 user5Shares = escrow.balanceOf(user5);
        escrow.redeem(user5Shares);
        assertEq(sInv.balanceOf(user5), user5Shares, "User5 should receive sINV tokens");
        assertEq(escrow.balanceOf(user5), 0, "User5's shares should be burned");
        sInv.redeem(user5Shares, user5, user5);
        assertGt(inv.balanceOf(user5), 12000 ether, "User5 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        // User6 redeems lsINV shares
        vm.startPrank(user6);
        uint256 user6Shares = escrow.balanceOf(user6);
        escrow.redeem(user6Shares);
        assertEq(sInv.balanceOf(user6), user6Shares, "User6 should receive sINV tokens");
        assertEq(escrow.balanceOf(user6), 0, "User6's shares should be burned");
        sInv.redeem(user6Shares, user6, user6);
        assertGt(inv.balanceOf(user6), 5000 ether, "User6 should have INV tokens after redeeming sINV");
        vm.stopPrank();

        assertEq(escrow.totalSupply(), 0, "Escrow total supply should be zero after all redemptions");
        assertEq(sInv.balanceOf(address(escrow)), 0, "Escrow should have no sINV after redemptions");
    }
}

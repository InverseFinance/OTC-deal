// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISaleHandler {
    function onReceive() external;
    function getCapacity() external view returns (uint256);
}

/**
 * @title OTCDeal
 * This contract allows users to buy lsINV shares (1:1 with sINV shares) using DOLA, with a specific commitment on the amount of INV they can purchase.
 * INV tokens bought are deposited into sINV vault.
 * After the redemption timestamp has passed, users can redeem their lsINV shares for INV tokens.
 */
contract OTCDeal is ERC20 {
    using SafeERC20 for IERC20;

    IERC4626 public constant sINV = IERC4626(0x08d23468A467d2bb86FaE0e32F247A26C7E2e994);
    IERC20 public constant INV = IERC20(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);
    IERC20 public constant DOLA = IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);
    ISaleHandler public constant SALE_HANDLER = ISaleHandler(0xB4497A7351e4915182b3E577B3A2f411FA66b27f);

    // The sweep timestamp is set to 1 year from deployment, after which the operator can sweep any remaining tokens.
    uint256 public immutable sweepTimestamp;
    uint256 public immutable invPrice;

    address public operator;
    address public pendingOperator;
    uint256 public buyDeadline; // The deadline for buying lsINV tokens, set to 4 days after the buy period starts.
    uint256 public redemptionTimestamp; // The timestamp after which users can redeem their lsINV shares for INV tokens.
    mapping(address => uint256) public dolaCommitments; // DOLA user commitment for vested INV purchases

    event DolaCommitmentSet(address indexed user, uint256 commitment);
    event Repayment(address indexed user, uint256 amount);
    event Buy(address indexed user, uint256 dolaAmount, uint256 invAmount, uint256 shares);
    event Redeem(address indexed user, uint256 shares, uint256 invAmount);
    event BuyDeadlineUpdated(uint256 newDeadline);
    event NewPendingOperator(address indexed newOperator);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event Repayment(uint256 amount);
    event Sweep(address indexed token, uint256 amount);
    event VestingStarted(uint256 redemptionTimestamp);

    constructor(address _operator, uint256 _invPrice) ERC20("lsINV", "lsINV") {
        operator = _operator;
        sweepTimestamp = block.timestamp + 365 days; // 1 year from deployment
        invPrice = _invPrice; // Set the INV price for conversion
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Only operator");
        _;
    }

    /**
     * @notice Allows users to buy lsINV tokens using DOLA. lsINV can be redeemed for INV after the redemption period.
     * @dev The user must have a commitment set for the exact amount of DOLA they can spend.
     * @param dolaAmountIn The amount of DOLA to spend.
     * @return shares The number of lsINV shares purchased.
     */
    function buy(uint256 dolaAmountIn) external returns (uint256 shares) {
        require(block.timestamp <= buyDeadline, "Buy period ended or not started");
        require(dolaAmountIn > 0, "DOLA amount must be greater than zero");
        require(dolaCommitments[msg.sender] == dolaAmountIn, "Can only buy exact commitment amount");

        dolaCommitments[msg.sender] = 0;

        DOLA.safeTransferFrom(msg.sender, address(this), dolaAmountIn);
        uint256 invAmount = dolaAmountIn * 1 ether / invPrice;
        INV.safeTransferFrom(operator, address(this), invAmount);
        INV.approve(address(sINV), invAmount);

        uint256 expectedShares = sINV.previewDeposit(invAmount);
        shares = sINV.deposit(invAmount, address(this));
        require(shares >= expectedShares, "Insufficient shares received");

        _mint(msg.sender, shares);

        emit Buy(msg.sender, dolaAmountIn, invAmount, shares);
    }

    /**
     * @notice Allows users to redeem their lsINV shares for INV tokens after the redemption period.
     * @dev Users must wait until the redemption timestamp to redeem their shares.
     * @param shares The number of lsINV shares to redeem.
     * @return invAmount The amount of INV tokens received.
     */
    function redeem(uint256 shares) external returns (uint256 invAmount) {
        require(block.timestamp >= redemptionTimestamp && redemptionTimestamp != 0, "Redemption not started yet");
        require(shares > 0, "Shares must be greater than zero");

        _burn(msg.sender, shares);

        uint256 expectedInvAmount = sINV.previewRedeem(shares);
        invAmount = sINV.redeem(shares, msg.sender, address(this));
        require(invAmount >= expectedInvAmount, "Insufficient INV received");

        emit Redeem(msg.sender, shares, invAmount);
    }

    /**
     * @notice Allows anyone to send DOLA to the sale handler for debt repayment.
     * Will send up to the Sale Handler capacity.
     */
    function sendToSaleHandler() external {
        uint256 bal = DOLA.balanceOf(address(this));
        require(bal > 0, "No DOLA to send");
        uint256 capacity = SALE_HANDLER.getCapacity();
        uint256 amount = bal > capacity ? capacity : bal;
        DOLA.transfer(address(SALE_HANDLER), amount);
        SALE_HANDLER.onReceive();
        emit Repayment(amount);
    }

    // Admin functions

    /**
     * @notice Sets a commitment for a user on how much DOLA they can spend to buy lsINV.
     * @dev Only the operator can set DOLA Commitments. This is used to control the amount of INV each user can purchase.
     * @param user The address of the user to set the commitment for.
     * @param commitment The amount of DOLA the user is allowed to spend.
     */
    function setDolaCommitment(address user, uint256 commitment) external onlyOperator {
        dolaCommitments[user] = commitment;
        emit DolaCommitmentSet(user, commitment);
    }

    /**
     * @notice Starts the buy period by setting the buy deadline to 4 days from now.
     * @dev This function can only be called by the operator. It allows users to start buying lsINV tokens.
     * The buy period lasts for 4 days.
     */
    function startBuyPeriod() external onlyOperator {
        buyDeadline = block.timestamp + 4 days;
        emit BuyDeadlineUpdated(buyDeadline);
    }

    /**
     * @notice Extends the buy deadline by a specified number of days.
     * @dev This function can only be called by the operator. It allows the operator to extend the buy period if needed.
     * @param extraDays The number of days to extend the buy deadline by.
     */
    function extendDeadline(uint256 extraDays) external onlyOperator {
        buyDeadline = block.timestamp + (extraDays * 1 days);
        emit BuyDeadlineUpdated(buyDeadline);
    }

    /**
     * @notice Starts the vesting period by setting the redemption timestamp to 6 months
     * @dev This function can only be called by the operator. After this timestamp, users can redeem their lsINV shares for INV tokens.
     */
    function startVesting() external onlyOperator {
        redemptionTimestamp = block.timestamp + 180 days; // 6 months from now
        emit VestingStarted(redemptionTimestamp);
    }
    /**
     * @notice Allows the operator to sweep any remaining tokens after the sweep timestamp (1 year from deployment).
     * @dev This function can only be called by the operator. It transfers all remaining tokens of a specified type to the operator.
     * @param token The address of the token to sweep.
     */

    function sweep(address token) external onlyOperator {
        require(block.timestamp >= sweepTimestamp, "Sweep not allowed yet");
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(operator, balance);
        emit Sweep(token, balance);
    }

    /**
     * @notice Allows the operator to set a new pending operator for ownership transfer.
     * @dev This function can only be called by the current operator. The new operator must accept the transfer.
     * @param newOperator The address of the new pending operator.
     */
    function setPendingOperator(address newOperator) external onlyOperator {
        pendingOperator = newOperator;
        emit NewPendingOperator(newOperator);
    }

    /**
     * @notice Allows the pending operator to accept the ownership transfer.
     * @dev This function can only be called by the pending operator. After acceptance, the pending operator becomes the new operator.
     */
    function acceptOperator() external {
        require(msg.sender == pendingOperator, "Only pending operator can accept");
        emit OperatorChanged(operator, pendingOperator);
        operator = pendingOperator;
        pendingOperator = address(0);
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ISaleHandler {
    function onReceive() external;
}

interface IAnDola {
    function borrowBalanceStored(address borrower) external view returns (uint256);
}
/**
 * @title RepayRewardEscrow
 * This contract allows users to buy lsINV shares (1:1 with sINV shares) using DOLA, with a specific allocation on the amount of INV they can purchase.
 * INV tokens bought are deposited into sINV vault.
 * After the redemption timestamp has passed, users can redeem their lsINV for sINV shares.
 */

contract RepayRewardEscrow is ERC20 {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    IERC4626 public constant sINV = IERC4626(0x08d23468A467d2bb86FaE0e32F247A26C7E2e994);
    IERC20 public constant INV = IERC20(0x41D5D79431A913C4aE7d69a668ecdfE5fF9DFB68);
    IERC20 public constant DOLA = IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4);
    ISaleHandler public constant SALE_HANDLER = ISaleHandler(0xB4497A7351e4915182b3E577B3A2f411FA66b27f);
    uint256 public constant INV_PRICE = 25 ether; // The price of INV in DOLA, set to 25 DOLA per INV.
    IAnDola public constant AnDOLA = IAnDola(0x7Fcb7DAC61eE35b3D4a51117A7c58D53f0a8a670);
    address public constant anDolaBorrower1 = address(0xf508c58ce37ce40a40997C715075172691F92e2D); // anDola borrower1 in the Sale Handler

    // The sweep timestamp is set to 1 year from deployment, after which the operator can sweep any remaining tokens.
    uint256 public immutable sweepTimestamp;

    address public operator;
    address public gov;
    address public pendingGov;
    uint256 public buyDeadline; // The deadline for buying lsINV tokens, set to 4 days after the buy period starts.
    uint256 public redemptionTimestamp; // The timestamp after which users can redeem their lsINV shares for INV tokens, set to 6 months after the buy period starts.
    mapping(address => uint256) public dolaAllocations; // DOLA user allocation for vested INV purchases

    event DolaAllocationSet(address indexed user, uint256 allocation);
    event Buy(address indexed user, uint256 dolaAmount, uint256 invAmount, uint256 lsInvOut);
    event Redeem(address indexed user, uint256 sInvAmount);
    event BuyDeadlineUpdated(uint256 newDeadline);
    event NewPendingGov(address indexed newOperator);
    event OperatorChanged(address indexed oldOperator, address indexed newOperator);
    event GovChanged(address indexed oldGov, address indexed newGov);
    event DolaRepayment(uint256 amount);
    event Sweep(address indexed token, uint256 amount);
    event VestingStarted(uint256 redemptionTimestamp);

    constructor(address _gov, address _operator) ERC20("lsINV", "lsINV") {
        gov = _gov;
        operator = _operator;
        sweepTimestamp = block.timestamp + 365 days; // 1 year from deployment
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Only operator");
        _;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Only governance");
        _;
    }

    /**
     * @notice Allows users to buy lsINV tokens using DOLA. lsINV can be redeemed for sINV after the redemption period.
     * @dev The user must have a allocation set for the exact amount of DOLA they can spend and approve this contract to spend it.
     * @param minLsInvOut The minimum amount of lsINV shares the user expects to receive (1:1 with sINV).
     * @return lsInvOut The number of lsINV shares purchased.
     */
    function buy(uint256 minLsInvOut) external returns (uint256 lsInvOut) {
        require(block.timestamp <= buyDeadline, "Buy period ended or not started");
        require(dolaAllocations[msg.sender] != 0, "No DOLA allocation set for user");

        uint256 dolaAmountIn = dolaAllocations[msg.sender];

        DOLA.safeTransferFrom(msg.sender, address(this), dolaAmountIn);
        uint256 invAmount = dolaAmountIn * 1 ether / INV_PRICE;
        INV.safeTransferFrom(gov, address(this), invAmount);
        INV.approve(address(sINV), invAmount);

        lsInvOut = sINV.deposit(invAmount, address(this));
        require(lsInvOut >= minLsInvOut, "Insufficient shares received");

        _mint(msg.sender, lsInvOut);

        dolaAllocations[msg.sender] = 0;

        emit Buy(msg.sender, dolaAmountIn, invAmount, lsInvOut);
    }

    /**
     * @notice Allows users to redeem their lsINV shares for sINV tokens after the redemption period.
     * @dev Users must wait until the redemption timestamp to redeem their shares.
     * @param lsInvAmount The number of lsINV shares to redeem.
     */
    function redeem(uint256 lsInvAmount) external {
        require(block.timestamp >= redemptionTimestamp && redemptionTimestamp != 0, "Redemption not started yet");
        require(lsInvAmount > 0, "lsInvAmount must be greater than zero");

        _burn(msg.sender, lsInvAmount);

        sINV.safeTransfer(msg.sender, lsInvAmount);

        emit Redeem(msg.sender, lsInvAmount);
    }

    // Admin functions

    /**
     * @notice Send DOLA to the sale handler for debt repayment.
     * @dev Only the operator can call this function. Will send up to the Sale Handler capacity for anDOLA borrower1.
     * @param dolaAmount The amount of DOLA to send to the sale handler.
     */
    function sendToSaleHandler(uint256 dolaAmount) external onlyOperator {
        uint256 bal = DOLA.balanceOf(address(this));
        require(bal > 0, "No DOLA to send");
        uint256 amount = dolaAmount > bal ? bal : dolaAmount;
        uint256 capacity = AnDOLA.borrowBalanceStored(anDolaBorrower1);
        amount = amount > capacity ? capacity : amount;
        DOLA.transfer(address(SALE_HANDLER), amount);
        SALE_HANDLER.onReceive();
        emit DolaRepayment(amount);
    }

    /**
     * @notice Sets a allocation for a user on how much DOLA they can spend to buy lsINV.
     * @dev Only the operator can set DOLA allocations. This is used to control the amount of INV each user can purchase.
     * @param user The address of the user to set the allocation for.
     * @param allocation The amount of DOLA the user is allowed to spend.
     */
    function setDolaAllocation(address user, uint256 allocation) external onlyOperator {
        dolaAllocations[user] = allocation;
        emit DolaAllocationSet(user, allocation);
    }

    /**
     * @notice Set the buy deadline by a specified number of days.
     * @dev This function can only be called by the operator. It allows the operator to set the buy period if needed.
     * @param newDeadline The timestamp for the new deadline for buying lsINV tokens.
     */
    function setDeadline(uint256 newDeadline) external onlyOperator {
        buyDeadline = newDeadline;
        emit BuyDeadlineUpdated(buyDeadline);
    }

    /**
     * @notice Starts the buy period by setting the buy deadline to 4 days and the redemption timestamp to 6 months from now.
     * @dev This function can only be called by governance. It allows users to start buying lsINV tokens.
     * The buy period lasts for 4 days.
     */
    function start() external onlyGov {
        require(redemptionTimestamp == 0, "Already started");
        buyDeadline = block.timestamp + 4 days;
        redemptionTimestamp = block.timestamp + 180 days;
        emit BuyDeadlineUpdated(buyDeadline);
        emit VestingStarted(redemptionTimestamp);
    }

    /**
     * @notice Allows governance to sweep any remaining tokens after the sweep timestamp (1 year from deployment).
     * @dev This function can only be called by governance. It transfers all remaining tokens of a specified type to the operator.
     * @param token The address of the token to sweep.
     */
    function sweep(address token) external onlyGov {
        require(block.timestamp >= sweepTimestamp, "Sweep not allowed yet");
        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(gov, balance);
        emit Sweep(token, balance);
    }

    /**
     * @notice Allows governance to withdraw DOLA from the contract.
     * @dev This function can only be called by governance. It transfers the specified amount of DOLA to the given address.
     * @param to The address to send the DOLA to.
     * @param amount The amount of DOLA to withdraw.
     */
    function withdrawDOLA(address to, uint256 amount) external onlyGov {
        require(amount > 0, "Amount must be greater than zero");
        DOLA.safeTransfer(to, amount);
    }

    /**
     * @notice Allows the governance to set a new pending governance for ownership transfer.
     * @dev This function can only be called by the current governance. The new governance must accept the transfer.
     * @param newGov The address of the new pending governance.
     */
    function setPendingGov(address newGov) external onlyGov {
        pendingGov = newGov;
        emit NewPendingGov(newGov);
    }

    /**
     * @notice Allows the pending goverance to accept the ownership transfer.
     * @dev This function can only be called by the pending goverance. After acceptance, the pending goverance becomes the new goverance.
     */
    function acceptGov() external {
        require(msg.sender == pendingGov, "Only pending gov can accept");
        emit GovChanged(gov, pendingGov);
        gov = pendingGov;
        pendingGov = address(0);
    }

    /**
     * @notice Allows the governance to set a new operator.
     * @dev This function can only be called by the current governance. The new operator will have permissions to manage allocations and extend deadlines.
     * @param newOperator The address of the new operator.
     */
    function setOperator(address newOperator) external onlyGov {
        emit OperatorChanged(operator, newOperator);
        operator = newOperator;
    }
}

## OTC Deal
This repo contains a contract, `RepayRewardEscrow` that facilitates trades from INV to DOLA, and automatically uses the acquired DOLA to repay bad debt incurred in a previous security incidence.

### RepayRewardEscrow

The contract has the following features:

- An operator role that can add/remove whitelisted participants each with an amount of DOLA they must contribute.
- Whitelisted participants can buy INVs for 25 DOLA price for their allowed limit.
- INV is pulled from the Inverse Finance DAO treasury address using an INV allowance provided by governance.
- INV is NOT immediately given to the purchaser. It is instead deposited into sINV (Staked Inverse). Another token called lsINV is minted to the user in an equal amount of the created sINV tokens.
- The user can redeem each lsINV for 1 sINV after 6 months or more from the deployment of the contract.
- Governance can sweep any tokens in the contract (including sINV) after 1 year of contract deployment in emergency case where funds are stuck.
- The contract has a short window where trades can be executed after activation. This prevents the purchaser from having a free option on Inverse at 25 DOLA, should they not make the purchase in reasonable time.
- DOLA funds are sent to the `SaleHandler` contract which has previously been used to repay bad DOLA debt.

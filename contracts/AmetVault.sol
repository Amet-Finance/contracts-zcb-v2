// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IZeroCouponBonds} from "./interfaces/IZeroCouponBonds.sol";
import {IZeroCouponBondsIssuer} from "./interfaces/IZeroCouponBondsIssuer.sol";
import {CoreTypes} from "./libraries/CoreTypes.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAmetVault} from "./interfaces/IAmetVault.sol";

contract AmetVault is Ownable, IAmetVault {
    using SafeERC20 for IERC20;

    struct ReferrerInfo {
        uint40 count;
        bool isRepaid;
    }

    event FeesWithdrawn(address toAddress, uint256 amount, bool isERC20);
    event ReferralPurchaseFeeChanged(uint8 fee);
    event ReferralRecord(address bondContractAddress, address referrer, uint40 amount);
    event ReferrerRewardClaimed(address referrer, uint256 amount);

    address public immutable issuerContract;
    uint8 private referrerPurchaseFeePercentage;

    mapping(address bondContract => mapping(address referrer => ReferrerInfo)) public referrers;

    modifier onlyAuthorizedContracts(address bondContractAddress) {
        require(IZeroCouponBondsIssuer(issuerContract).issuedContracts(bondContractAddress), "Contract is not valid");
        _;
    }

    receive() external payable {}

    constructor(address _initialIssuerContract) Ownable(msg.sender) {
        issuerContract = _initialIssuerContract;
    }

    ///////////////////////////////////
    //        Referral logic        //
    /////////////////////////////////

    /// @dev Records referral purchase for the bond contract
    /// @param referrer - address of the referrer
    /// @param count - count of the bonds that was purchased by the referral
    function recordReferralPurchase(address referrer, uint40 count) external onlyAuthorizedContracts(msg.sender) {
        referrers[msg.sender][referrer].count += count;
        emit ReferralRecord(msg.sender, referrer, count);
    }

    /// @dev After the bond contract is settled, referrers can claim their rewards
    /// @param bondContractAddress - the address of the bond contract
    function claimReferralRewards(address bondContractAddress) external onlyAuthorizedContracts(bondContractAddress) {
        ReferrerInfo storage referrer = referrers[bondContractAddress][msg.sender];
        require(!referrer.isRepaid && referrer.count != 0);

        IZeroCouponBonds bondContract = IZeroCouponBonds(bondContractAddress);

        if (isSettledAndFullyPurchased(bondContract)) {
            referrer.isRepaid = true;
            uint256 rewardAmount =
                (((referrer.count * bondContract.interestAmount()) * referrerPurchaseFeePercentage) / 1000);
            IERC20(bondContract.interestToken()).safeTransfer(msg.sender, rewardAmount);
            emit ReferrerRewardClaimed(msg.sender, rewardAmount);
        }
    }

    ///////////////////////////////////
    //     Only owner functions     //
    /////////////////////////////////

    
    /// @dev Withdraws the Ether(issuance fees)
    /// @param toAddress - address to transfer token
    /// @param amount - amount to transfer
    function withdrawETH(address toAddress, uint256 amount) external onlyOwner {
        (bool success,) = toAddress.call{value: amount}("");
        require(success);
        emit FeesWithdrawn(toAddress, amount, false);
    }

    /// @dev Withdraws the ERC20 token(purchase fees)
    /// @param toAddress - address to transfer token
    /// @param amount - amount to transfer
    function withdrawERC20(address token, address toAddress, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(toAddress, amount);
        emit FeesWithdrawn(toAddress, amount, true);
    }

    /// @dev Changes the Referrer Purchase Fee percentage
    /// @param fee - new fee value
    function changeReferrerPurchaseFeePercentage(uint8 fee) external onlyOwner {
        referrerPurchaseFeePercentage = fee;
        emit ReferralPurchaseFeeChanged(fee);
    }

    ////////////////////////////////////
    //       View only functions     //
    //////////////////////////////////

    /// @dev - returns true if contract can not issue more bonds && fully repaid the purchasers && totally purchased
    function isSettledAndFullyPurchased(IZeroCouponBonds bondContract) internal view returns (bool) {
        CoreTypes.BondInfo memory bondInfoLocal = bondContract.bondInfo();
        return bondInfoLocal.isSettled && bondInfoLocal.total == bondInfoLocal.purchased;
    }
}

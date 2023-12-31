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

    event ReferralPurchaseFeeChanged(uint8 fee);
    event ReferralRecord(address bondContractAddress, address referrer, uint40 amount);

    address public immutable issuerContract;
    uint8 private referrerPurchaseFeePercentage;

    mapping(address bondContract => mapping(address referrer => ReferrerInfo)) public referrers;

    modifier onlyAuthorizedContracts(address bondContractAddress) {
        require(IZeroCouponBondsIssuer(issuerContract).issuedContracts(bondContractAddress), "Contract is not valid");
        _;
    }

    receive() external payable {

    }

    constructor(address _initialIssuerContract) Ownable(msg.sender) {
        issuerContract = _initialIssuerContract;
    }

    ///////////////////////////////////
    //        Referral logic        //
    /////////////////////////////////


    function recordReferralPurchase(address referrer, uint40 count) external onlyAuthorizedContracts(msg.sender) {
        emit ReferralRecord(msg.sender, referrer, count);
        referrers[msg.sender][referrer].count += count;
    }

    function claimReferralRewards(address bondContractAddress) external onlyAuthorizedContracts(bondContractAddress) {
        ReferrerInfo storage referrer = referrers[bondContractAddress][msg.sender];
        require(!referrer.isRepaid && referrer.count != 0);

        IZeroCouponBonds bondContract = IZeroCouponBonds(bondContractAddress);

        if (isSettledAndFullyPurchased(bondContract)) {
            referrer.isRepaid = true;
            IERC20(bondContract.interestToken()).safeTransfer(
                msg.sender, (((referrer.count * bondContract.interestAmount()) * referrerPurchaseFeePercentage) / 1000)
            );
        }
    }


    ///////////////////////////////////
    //     Only owner functions     //
    /////////////////////////////////

    function withdrawERC20(address token, address toAddress, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(toAddress, amount);
    }

    function changeReferrerPurchaseFeePercentage(uint8 fee) external onlyOwner {
        emit ReferralPurchaseFeeChanged(fee);
        referrerPurchaseFeePercentage = fee;
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

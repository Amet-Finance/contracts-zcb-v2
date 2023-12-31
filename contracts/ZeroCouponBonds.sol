// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
/**
 * 00000000 00    00 00000000 00000000
 * 00    00 000  000 00          00
 * 00    00 00 00 00 00          00
 * 00    00 00    00 00          00
 * 00000000 00    00 00000000    00
 * 00    00 00    00 00          00
 * 00    00 00    00 00          00
 * 00    00 00    00 00000000    00
 *
 *
 *
 * @title Amet Finance ZeroCouponBondsV2
 * @dev
 *
 * Author: @TheUnconstrainedMind
 * Created: 20 Dec 2023
 *
 * Optional:
 * - Change chainId in the _uri
 */

import {IAmetVault} from "./interfaces/IAmetVault.sol";
import {CoreTypes} from "./libraries/CoreTypes.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract ZeroCouponBonds is ERC1155, Ownable {
    using SafeERC20 for IERC20;

    enum OperationCodes {
        InsufficientInterest,
        RedemptionBeforeMaturity,
        InvalidAction
    }

    error OperationFailed(OperationCodes code);

    event SettleContract();
    event UpdateBondSupply(uint40 total);
    event DecreaseMaturityThreshold(uint40 maturityThreshold);

    string private constant BASE_URI = "https://storage.amet.finance/1/contracts" ;
    address public immutable vault;

    CoreTypes.BondInfo public bondInfo;

    address public immutable investmentToken;
    uint256 public immutable investmentAmount;

    address public immutable interestToken;
    uint256 public immutable interestAmount;

    mapping(uint40 tokenId => uint256 blockNumber) public bondPurchaseBlocks;

    constructor(
        address _initialIssuer,
        address _initialVault,
        CoreTypes.BondInfo memory _initialBondInfo,
        address _initialInvestmentToken,
        uint256 _initialInvestmentAmount,
        address _initialInterestToken,
        uint256 _initialInterestAmount
    )
        ERC1155(string.concat(BASE_URI, Strings.toHexString(address(this)), ".json"))
        Ownable(_initialIssuer)
    {
        vault = _initialVault;

        bondInfo = _initialBondInfo;

        investmentToken = _initialInvestmentToken;
        investmentAmount = _initialInvestmentAmount;

        interestToken = _initialInterestToken;
        interestAmount = _initialInterestAmount;
    }

    /// @dev Before calling this function, the msg.sender should update the allowance of interest token for the bond contract
    /// @param count - count of the bonds that will be purchased
    function purchase(uint40 count, address referrer) external {

        CoreTypes.BondInfo storage bondInfoTmp = bondInfo;
        address vaultAddress = vault;

        if (bondInfoTmp.purchased + count > bondInfoTmp.total) revert OperationFailed(OperationCodes.InvalidAction);

        IERC20 investment = IERC20(investmentToken);
        uint256 totalAmount = count * investmentAmount;

        bondInfoTmp.purchased += count;
        bondPurchaseBlocks[bondInfoTmp.uniqueBondIndex] = block.number;

        _mint(msg.sender, bondInfoTmp.uniqueBondIndex, count, "");
        bondInfoTmp.uniqueBondIndex += 1;

        uint256 purchaseFee = (totalAmount * bondInfoTmp.purchaseFeePercentage) / 1000;
        if (referrer != address(0)) {
            IAmetVault(vaultAddress).recordReferralPurchase(referrer, count);
        }

        investment.safeTransferFrom(msg.sender, vaultAddress, purchaseFee);
        investment.safeTransferFrom(msg.sender, owner(), totalAmount - purchaseFee);
    }

    /// @dev The function will redeem the bonds and transfer interest tokens to the msg.sender
    /// @param bondIndexes - array of the bond Indexes
    /// @param redemptionCount  - the count of the bonds that will be redeemed
    function redeem(uint40[] calldata bondIndexes, uint40 redemptionCount, bool isCapitulation) external {
        uint256 interestAmountToBePaid = interestAmount;
        CoreTypes.BondInfo storage bondInfoTmp = bondInfo;

        uint256 amountToBePaid = redemptionCount * interestAmountToBePaid;
        IERC20 interest = IERC20(interestToken);

        bondInfoTmp.redeemed += redemptionCount;

        if (amountToBePaid > interest.balanceOf(address(this)) && !isCapitulation) {
            revert OperationFailed(OperationCodes.InsufficientInterest);
        }

        uint256 bondIndexesLength = bondIndexes.length;

        for (uint40 i; i < bondIndexesLength;) {
            uint40 bondIndex = bondIndexes[i];
            uint256 purchasedBlock = bondPurchaseBlocks[bondIndex];

            if (purchasedBlock + bondInfoTmp.maturityThreshold > block.number && !isCapitulation) {
                revert OperationFailed(OperationCodes.RedemptionBeforeMaturity);
            }

            uint40 balanceByIndex = uint40(balanceOf(msg.sender, bondIndex));
            uint40 burnCount = balanceByIndex >= redemptionCount ? redemptionCount : balanceByIndex;

            _burn(msg.sender, bondIndex, redemptionCount);
            redemptionCount -= burnCount;

            if (isCapitulation) {
                uint256 blocksPassed = block.number - purchasedBlock;

                uint256 amountToBePaidOG = burnCount * interestAmountToBePaid;

                uint256 bondsAmountForCapitulation = ((burnCount * blocksPassed * interestAmountToBePaid)) / bondInfoTmp.maturityThreshold;
                uint256 feeDeducted = bondsAmountForCapitulation - ((bondsAmountForCapitulation * bondInfoTmp.earlyRedemptionFeePercentage) / 1000);

                amountToBePaid -= (amountToBePaidOG - feeDeducted);
            }

            if (redemptionCount == 0) break;
            unchecked {
                i += 1;
            }
        }

        if (redemptionCount != 0) {
            revert OperationFailed(OperationCodes.InvalidAction);
        }

        interest.safeTransfer(msg.sender, amountToBePaid);
    }

    ////////////////////////////////////
    //      Only Owner functions     //
    //////////////////////////////////

    /// @dev When settling contract it means that no other bond can be issued/burned and the interest amount should be equal to (total - redeemed) * interestAmount
    /// isSettled adds the lvl of security. Bond purchasers can be sure that no other bond can be issued and the bond is totally redeemable
    function settleContract() external onlyOwner {
        CoreTypes.BondInfo storage bondInfoLocal = bondInfo;
        IERC20 interest = IERC20(interestToken);
        uint256 totalInterestRequired = (bondInfoLocal.total - bondInfoLocal.redeemed) * interestAmount;

        if (totalInterestRequired > interest.balanceOf(address(this))) {
            revert OperationFailed(OperationCodes.InsufficientInterest);
        }

        emit SettleContract();
        bondInfoLocal.isSettled = true;
    }

    /// @dev For withdrawing the excess interest that was accidentally deposited to the contract
    /// @param toAddress - the address to send the excess interest
    function withdrawExcessInterest(address toAddress) external onlyOwner {
        CoreTypes.BondInfo memory bondInfoLocal = bondInfo;
        uint256 requiredAmountForTotalRedemption = (bondInfoLocal.total - bondInfoLocal.redeemed) * interestAmount;
        IERC20 interest = IERC20(interestToken);

        uint256 interestBalance = interest.balanceOf(address(this));
        if (interestBalance <= requiredAmountForTotalRedemption) {
            revert OperationFailed(OperationCodes.InsufficientInterest);
        }

        interest.safeTransfer(toAddress, interestBalance - requiredAmountForTotalRedemption);
    }

    /// @dev Decreses maturity treshold of the bond
    /// @param newMaturityThreshold - new decreased maturity threshold 
    function decreaseMaturityThreshold(uint40 newMaturityThreshold) external onlyOwner {
        CoreTypes.BondInfo storage bondInfoLocal = bondInfo;
        if (newMaturityThreshold >= bondInfoLocal.maturityThreshold) revert OperationFailed(OperationCodes.InvalidAction);
        emit DecreaseMaturityThreshold(newMaturityThreshold);
        bondInfoLocal.maturityThreshold = newMaturityThreshold;
    }

    /// @dev updates the bond total supply, checks if you put more than was purchased
    /// @param total - new total value
    function updateBondSupply(uint40 total) external onlyOwner {
        CoreTypes.BondInfo storage bondInfoLocal = bondInfo;
        if (bondInfoLocal.isSettled || bondInfoLocal.purchased > total) {
            revert OperationFailed(OperationCodes.InvalidAction);
        }
        emit UpdateBondSupply(total);
        bondInfoLocal.total = total;
    }
}

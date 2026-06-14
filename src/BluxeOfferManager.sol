// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BluxeOfferManager
/// @author Izaq (Bluxe Labs)
/// @notice Manages ETH and WETH offers for NFT listings in the Bluxe MARKETPLACE
/// @custom:github https://github.com/0xSmartCoder
/// @custom:linkedin https://www.linkedin.com/in/izaq-b8674233a

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BluxeStorage} from "./BluxeStorage.sol";

/// @dev Custom Errors
error ListingNotActive(uint256);
error NotEnoughAllowance(uint256);
error AmountZero(uint256);
error NotActiveOffer();
error InvalidOfferState();
error NotListingOwner(address);
error AlreadyResolved();
error NFTNotInEscrow(uint256);
error CannotMakeOfferToOwnListing(address);
error NoOfferFromBuyerWhileWeTryToAccept(address);
error TopOfferCannotBeReduced();
error RefundNotAvailable();
error CannotMakeOfferAnAuctionListing(uint256);
error _OnlyMarketplace();
error ListingStillActive();
error EthForwardFailed();
contract BluxeOfferManager is ReentrancyGuard {
    using SafeERC20 for IERC20;
    BluxeStorage public store;

    // ----- Events -----
    event OfferPlaced(
        address indexed nftContract,
        address indexed offerMaker,
        address seller,
        uint256 indexed tokenId,
        uint256 price,
        uint256 listingId,
        BluxeStorage.OfferTokenType offertoken
    );
    event OfferCancelled(
        address indexed nftContract,
        address indexed offerCanceller,
        address seller,
        uint256 indexed tokenId,
        uint256 price,
        uint256 listingId
    );
    event OfferRefundable(
        address indexed nftContract,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 listingId
    );
    event Payout(
        address seller,
        uint sellerAmount,
        address royaltyReceiver,
        uint royalty,
        address platform,
        uint fee
    );

    constructor(address _bluxeStorageAdr) {
        store = BluxeStorage(_bluxeStorageAdr);
    }

    /// Modifier Only Marketplace!
    modifier onlyMarketplace() {
        if (msg.sender != store.marketplace()) revert _OnlyMarketplace();
        _;
    }

    // --------- Make an Offer (buyer sends wETH) ---------
    /// @dev Make an offer in wETH for an active listing
    function makeOfferWeth(uint256 listingId, uint256 offerAmount) external nonReentrant {
        BluxeStorage.Listing memory listing = store.getListing(listingId);

        if (offerAmount == 0) {
            revert AmountZero(offerAmount);
        }

        /// @notice Ensure that offers are only placed on active, non-auction listings
        if (!listing.active) {
            revert ListingNotActive(listing.tokenId);
        }

        /// @dev Rejects any attempt to make an offer on a listing that is either inactive or in auction mode
        /// @param listing The Listing struct of the NFT
        /// @param tokenId The token ID of the NFT being offered on
        if (listing.auction) {
            revert CannotMakeOfferAnAuctionListing(listing.tokenId);
        }

        // seller cannot make offer on their own listing
        if (msg.sender == listing.seller) {
            revert CannotMakeOfferToOwnListing(listing.seller);
        }

        /// @dev check previous offers of this Nft
        // Always refund the previous offer (if any) to the user's pendingWithdrawals,
        // even if the new offer is the same amount. This ensures users can safely update
        // their offer without risk of losing funds, but may result in accumulating withdrawable
        // balances if users repeatedly offer the same value.

        // Get Previous Offer Details
        (uint previousOfferAmount, BluxeStorage.OfferTokenType previousOfferTokenType) = store
            .getOffer(listingId, msg.sender);

        (address currentTopOfferer, , ) = store.getTopOffer(listingId);

        // Only top offerer cannot reduce
        if (msg.sender == currentTopOfferer) {
            if (offerAmount <= previousOfferAmount) {
                revert TopOfferCannotBeReduced();
            }
        }
        IERC20 wEth = IERC20(store.weth());
        /** @dev Transfer wETH from buyer to MARKETPLACE before proceeding with offer
         **/
        wEth.safeTransferFrom(msg.sender, address(store.marketplace()), offerAmount);

        // Refund previous offer if exists
        if (previousOfferAmount > 0) {
            if (previousOfferTokenType == BluxeStorage.OfferTokenType.ETH) {
                store.addPendingETH(msg.sender, previousOfferAmount);
            } else {
                store.addPendingWETH(msg.sender, previousOfferAmount);
            }
        }

        // record new offer & update top offer
        store.setOffer(listingId, msg.sender, offerAmount, BluxeStorage.OfferTokenType.WETH);

        emit OfferPlaced(
            listing.nftContract,
            msg.sender,
            listing.seller,
            listing.tokenId,
            offerAmount,
            listingId,
            BluxeStorage.OfferTokenType.WETH
        );
    }

    // --------- Make an Offer (buyer sends ETH) ---------
    function makeOfferEth(uint256 listingId) external payable nonReentrant {
        BluxeStorage.Listing memory listing = store.getListing(listingId);

        /// @notice Ensure that offers are only placed on active, non-auction listings
        if (!listing.active) {
            revert ListingNotActive(listing.tokenId);
        }

        if (msg.value == 0) {
            revert AmountZero(msg.value);
        }

        /// @dev Rejects any attempt to make an offer on a listing that is either inactive or in auction mode
        /// @param listing The Listing struct of the NFT
        /// @param tokenId The token ID of the NFT being offered on
        if (listing.auction) {
            revert CannotMakeOfferAnAuctionListing(listing.tokenId);
        }

        /// seller cannot make offer on their own listing
        if (msg.sender == listing.seller) {
            revert CannotMakeOfferToOwnListing(listing.seller);
        }

        /// @dev check previous offers of this Nft
        // Always refund the previous offer (if any) to the user's pendingWithdrawals,
        // even if the new offer is the same amount. This ensures users can safely update
        // their offer without risk of losing funds, but may result in accumulating withdrawable
        // balances if users repeatedly offer the same value.

        // Get Previous Offer Details
        (uint previousOfferAmount, BluxeStorage.OfferTokenType previousOfferTokenType) = store
            .getOffer(listingId, msg.sender);

        (address currentTopOfferer, , ) = store.getTopOffer(listingId);

        // Only top offerer cannot reduce
        if (msg.sender == currentTopOfferer) {
            if (msg.value <= previousOfferAmount) {
                revert TopOfferCannotBeReduced();
            }
        }

        // Refund previous offer if exists
        if (previousOfferAmount > 0) {
            if (previousOfferTokenType == BluxeStorage.OfferTokenType.ETH) {
                store.addPendingETH(msg.sender, previousOfferAmount);
            } else {
                store.addPendingWETH(msg.sender, previousOfferAmount);
            }
        }

        // record new offer & update top offer
        store.setOffer(listingId, msg.sender, msg.value, BluxeStorage.OfferTokenType.ETH);

        /// @dev Forward ETH immediately to Marketplace
        (bool ok, ) = payable(store.marketplace()).call{value: msg.value}("");
        if (!ok) revert EthForwardFailed();

        emit OfferPlaced(
            listing.nftContract,
            msg.sender,
            listing.seller,
            listing.tokenId,
            msg.value,
            listingId,
            BluxeStorage.OfferTokenType.ETH
        );
    }

    // ----- Cancel offer (Buyer cancel their offer and get refund via pendingWithdrawls ) -----
    function cancelOffer(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory listing = store.getListing(listingId);

        // Get Previous Offer Details
        (uint cancellerOfferAmount, BluxeStorage.OfferTokenType cancellerTokenType) = store
            .getOffer(listingId, msg.sender);

        (address currentTopOfferer, , ) = store.getTopOffer(listingId);

        if (cancellerOfferAmount <= 0) {
            revert NotActiveOffer();
        }

        /// @dev First Zero out the offer AMOUNT & offerer tokenType

        store.resetOfferAmountAndTokenType(listingId, msg.sender);

        /// @dev Recompute ONLY if top offerer cancelled
        if (msg.sender == currentTopOfferer) {
            store.recomputeTopOffer(listingId);
        }

        // clear out from is_Offerer
        store.clearisOfferer(listingId, msg.sender);

        // *Refund direct is dangerous so we keep it in pendingWithdrawls ;
        if (cancellerTokenType == BluxeStorage.OfferTokenType.WETH) {
            // wETH offer
            store.addPendingWETH(msg.sender, cancellerOfferAmount);
        } else {
            // ETH offer
            store.addPendingETH(msg.sender, cancellerOfferAmount);
        }

        emit OfferCancelled(
            listing.nftContract,
            msg.sender,
            listing.seller,
            listing.tokenId,
            cancellerOfferAmount,
            listingId
        );
    }

    // ----- Track Highest Offer (returns cached top offer if still valid) -----
    function trackHighestOffer(
        uint256 listingId
    )
        public
        view
        returns (address cachedBuyer, uint256 cachedAmount, BluxeStorage.OfferTokenType tokenType)
    {
        /// fast-path: if we have a cached top offer and it's still active, return it

        (cachedBuyer, cachedAmount, tokenType) = store.getTopOffer(listingId);
        /// validate cached top offer & return if still valid
        if (cachedBuyer != address(0) && cachedAmount > 0) {
            /**
             * NOTE:
             * We NEVER set isOfferer = false.
             *
             * Reason:
             * If we reset it to false, then when the same user makes a new offer,
             * the contract would push them into offerers[] again, causing duplicates.
             *
             * isOfferer is a one-time flag to prevent duplicate entries inside offerers[].
             * It does NOT represent whether the offer is currently active.
             */
            if (store.getIsOfferer(listingId, cachedBuyer) == true) {
                (uint currentAmount, BluxeStorage.OfferTokenType tokenType) = store.getOffer(
                    listingId,
                    cachedBuyer
                );
                if (currentAmount == cachedAmount) {
                    return (cachedBuyer, cachedAmount, tokenType);
                }
            }
        }

        /// If no valid cached offer, return default values
        return (address(0), 0, BluxeStorage.OfferTokenType.NONE);
    }

    /**
     * @notice Resolves and consumes a buyer's offer for a listing.
     * @dev Callable ONLY by the Marketplace contract.
     *      This function performs ONLY state updates and NO fund transfers.
     *
     * Security:
     * - Consumes the buyer's offer atomically.
     * - Marks listing inactive before any NFT transfer.
     * - Enables lazy refunds for all other offers.
     * - Protects against malicious NFTs and griefing via external calls.
     *
     * Flow:
     * 1. Validate listing is active.
     * 2. Validate buyer has an active offer.
     * 3. Consume buyer's offer.
     * 4. Clear cached top offer if applicable.
     * 5. Mark listing inactive.
     * 6. Mark other offers refundable (lazy refunds).
     *
     * @param buyer Address whose offer is being accepted.
     * @param listingId ID of the listing.
     *
     * @return winner Address of accepted buyer.
     * @return amount Accepted offer amount.
     * @return t Token type of the accepted offer (ETH or WETH).
     */
    function resolveOffer(
        address buyer,
        uint256 listingId
    )
        external
        nonReentrant
        onlyMarketplace
        returns (address winner, uint256 amount, BluxeStorage.OfferTokenType t)
    {
        BluxeStorage.Listing memory listing = store.getListing(listingId);

        // ---------- VALIDATION ----------

        /// ensure the listing is active before proceeding
        if (!listing.active) {
            revert ListingNotActive(listing.tokenId);
        }

        /// ensure offer exists from buyer
        (uint256 offerAmount, BluxeStorage.OfferTokenType buyerTokenType) = store.getOffer(
            listingId,
            buyer
        );

        if (offerAmount == 0) {
            revert NoOfferFromBuyerWhileWeTryToAccept(buyer);
        }

        if (store.isOfferRefundable(listingId)) {
            revert AlreadyResolved();
        }

        // consume buyer offer
        store.resetOfferAmountAndTokenType(listingId, buyer);

        /// Clear top offer and offerers
        store.resetTopOfferAndOfferers(listingId);

        /// mark listing non-active
        store.setListingActive(listingId, false);

        /// clear is-Offerer
        store.clearisOfferer(listingId, buyer);

        /// ----- Mark offer Refundable (Lazy Refund) instead of refund here -----
        /// All other offers on this listing will become refundable
        store.setOfferRefundable(listingId, true);
        emit OfferRefundable(listing.nftContract, listing.seller, listing.tokenId, listingId);

        return (buyer, offerAmount, buyerTokenType);
    }

    /**
     * @notice Distributes sale proceeds for an accepted offer.
     * @dev Callable ONLY by the Marketplace contract.
     *      All payments are credited to pending withdrawals.
     *
     * Security:
     * - Caps royalty to ensure (platform fee + royalty) <= sale price.
     * - Prevents malicious ERC2981 royalty griefing.
     * - Uses pull-based withdrawals to avoid reentrancy.
     *
     * Flow:
     * 1. Query royalty info if supported.
     * 2. Calculate platform fee.
     * 3. Cap royalty to remaining sale amount.
     * 4. Credit platform, royalty receiver, and seller balances.
     *
     * @param listing Listing struct for the sale.
     * @param amount Sale price.
     * @param offerTokenType Token used for payment (ETH or WETH).
     */
    function handleOfferPayouts(
        BluxeStorage.Listing memory listing,
        uint256 amount,
        BluxeStorage.OfferTokenType offerTokenType
    ) external onlyMarketplace {
        uint salePrice = amount;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);

        (uint96 platformFeeBps, address platformFeeRecipient) = store.getPlatformDetails();
        /// @notice get royalty if supported
        try IERC2981(listing.nftContract).royaltyInfo(listing.tokenId, salePrice) returns (
            address receiver,
            uint256 amount
        ) {
            royaltyAmount = amount;
            royaltyReceiver = receiver;
        } catch {
            royaltyAmount = 0;
            royaltyReceiver = address(0);
        }
        /// @dev Calculate platform fee
        uint256 platformFee = (salePrice * platformFeeBps) / 10_000;

        /// compute royalty to pay but cap so (platformFee + royaltyToPay) <= salePrice
        uint256 sellerAmount = 0;
        uint256 royaltyToPay = 0;

        if (platformFee >= salePrice) {
            /// platform takes all; no royalty or seller amount
            sellerAmount = 0;
            royaltyToPay = 0;
            if (offerTokenType == BluxeStorage.OfferTokenType.WETH) {
                // wETH offer
                store.addPendingWETH(platformFeeRecipient, salePrice);
            } else {
                // ETH offer
                store.addPendingETH(platformFeeRecipient, salePrice);
            }
        } else {
            uint256 maxRoyaltyPossible = salePrice - platformFee;
            if (royaltyReceiver != address(0) && royaltyAmount > 0) {
                // ------------- Same logic used in buyItem() for royalty payments -------------
                /**
                 * @dev We only pay royalties if both royaltyAmount > 0 and maxRoyaltyPossible > 0.
                 *
                 * Why check BOTH?
                 * - Some NFT contracts may return extremely high royalty amounts (even > sale price).
                 *   Example:
                 *       salePrice = 100
                 *       platformFee = 10
                 *       royaltyAmount = 150 (misconfigured contract)
                 *
                 * - In such cases, maxRoyaltyPossible = salePrice - platformFee = 90
                 *
                 * - So we must ensure:
                 *      We NEVER pay more royalty than what is realistically possible.
                 *
                 * This prevents:
                 * - Overpaying royalties
                 * - Losing contract funds
                 * - Getting exploited by faulty royalty implementations
                 */

                royaltyToPay = royaltyAmount > maxRoyaltyPossible
                    ? maxRoyaltyPossible
                    : royaltyAmount;

                assert(platformFee + royaltyToPay <= salePrice);

                if (royaltyToPay > 0) {
                    if (offerTokenType == BluxeStorage.OfferTokenType.WETH) {
                        // wETH offer
                        store.addPendingWETH(royaltyReceiver, royaltyToPay);
                    } else {
                        // ETH offer
                        store.addPendingETH(royaltyReceiver, royaltyToPay);
                    }
                }
            }

            /// remaining to the seller
            sellerAmount = salePrice - platformFee - royaltyToPay;

            /// pay platform fee
            if (platformFee > 0) {
                if (offerTokenType == BluxeStorage.OfferTokenType.WETH) {
                    // wETH offer
                    store.addPendingWETH(platformFeeRecipient, platformFee);
                } else {
                    // ETH offer
                    store.addPendingETH(platformFeeRecipient, platformFee);
                }
            }

            /// pay seller
            if (sellerAmount > 0) {
                if (offerTokenType == BluxeStorage.OfferTokenType.WETH) {
                    // wETH offer
                    store.addPendingWETH(listing.seller, sellerAmount);
                } else {
                    // ETH offer
                    store.addPendingETH(listing.seller, sellerAmount);
                }
            }
        }

        emit Payout(
            listing.seller,
            sellerAmount,
            royaltyReceiver,
            royaltyToPay,
            platformFeeRecipient,
            platformFee
        );
    }

    //----- Withdraw Refunded Offers (buyer withdraws their refundable offers) -----
    /**
     * @notice Withdraw and refund an active refundable offer on a listing.
     *
     * @dev This function allows an offerer to reclaim their ETH or WETH
     *      when the listing is marked as refundable. The refund is not sent
     *      directly to the user to avoid reentrancy and gas griefing risks.
     *      Instead, the amount is credited to the user's pending withdrawals.
     *
     * Requirements:
     * - The listing must be marked as refundable.
     * - Caller must have an active offer on the listing.
     *
     * Effects:
     * - Clears the caller's offer amount and token type.
     * - Removes caller from the offerer set.
     * - Credits the refundable amount to pending ETH or WETH withdrawals.
     *
     * @param listingId The ID of the listing for which the offer is being withdrawn.
     */
    function withdrawRefundableOffer(uint256 listingId) external nonReentrant {
        BluxeStorage.Listing memory l = store.getListing(listingId);

        /// ensure that offers on this listing are refundable
        if (!store.isOfferRefundable(listingId)) {
            revert RefundNotAvailable();
        }

        if (l.active) revert ListingStillActive();

        /// get active offer amount
        (uint amount, BluxeStorage.OfferTokenType tokenType) = store.getOffer(
            listingId,
            msg.sender
        );
        if (amount == 0) {
            revert NotActiveOffer();
        }

        if (tokenType == BluxeStorage.OfferTokenType.NONE) {
            revert InvalidOfferState();
        }

        // clear offer completely
        store.resetOfferAmountAndTokenType(listingId, msg.sender);
        store.clearisOfferer(listingId, msg.sender);

        // Refund direct is dangerous so we keep it in pendingWithdrawls ;
        if (tokenType == BluxeStorage.OfferTokenType.WETH) {
            // wETH offer
            store.addPendingWETH(msg.sender, amount);
        } else {
            // ETH offer
            store.addPendingETH(msg.sender, amount);
        }
    }
    receive() external payable {
        revert("NO_DIRECT_ETH");
    }
}

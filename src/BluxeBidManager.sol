// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BluxeBidManager
/// @author Izaq (Bluxe Labs)
/// @notice Handles ETH and WETH auction bids for the Bluxe MARKETPLACE

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BluxeStorage} from "./BluxeStorage.sol";

/// @dev Custom Errors
error _ListingIsNotInAuctionMode(uint256);
error _EthForwardFailed();
error BidAmountMustExceedCurrentPrice(uint256);
error SellerCannotBidOnOwnAuction(uint256);
error OnlyMarketplace();
error _ListingIsNotActive(uint256);
error AuctionEnded(uint256);
error _NftNotInTheEscrow(uint256);
error _AuctionNotEndedYet(uint256);
error CannotChangeBidTokenType();
error MustIncreaseYourOwnBid(uint256);
error ZeroBid();

contract BluxeBidManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// BID VARIABLES
    uint256 constant BID_INCREMENT_BPS = 500; // 5%
    uint256 constant MIN_INCREMENT = 0.01 ether; // min → 0.01 eth
    uint256 constant EXTENSION_DURATION = 5 minutes; // extend by → 5 min
    uint256 constant EXTENSION_WINDOW = 5 minutes; // last → 5 minutes

    BluxeStorage public store;

    /// Event
    event BidPlaced(
        address indexed nftContract,
        uint256 indexed tokenId,
        address seller,
        address indexed bidder,
        uint256 amount,
        BluxeStorage.BidTokenType tokenType,
        uint256 listingId
    );
    event AuctionResolved(
        address nftContract,
        uint256 tokenId,
        uint256 listingId,
        uint256 amount,
        address seller,
        address winner
    );
    event Payout(
        address seller,
        uint sellerAmount,
        address royaltyReceiver,
        uint royalty,
        address platform,
        uint fee
    );

    /// Modifier Only Marketplace
    modifier onlyMarketplace() {
        if (msg.sender != store.marketplace()) revert OnlyMarketplace();
        _;
    }

    constructor(address storageAdr) {
        store = BluxeStorage(storageAdr);
    }

    /**
     * @notice Places a bid on an active auction using native ETH.
     *
     * @dev
     * - Can only be called by the marketplace contract.
     * - Enforces minimum bid increment using both BPS and absolute ETH value.
     * - Automatically extends the auction end time if the bid is placed
     *   within the extension window.
     * - Refunds the previous highest bidder before recording the new bid.
     * - ETH is tracked as pending balance and paid out during finalization.
     *
     * @param listingId Marketplace listing identifier for the auction.
     */
    function placeBidEth(uint256 listingId) external payable nonReentrant {
        /// @dev Previous highest bidder
        (
            address previousHighestBidder,
            uint256 previousHighestBidAmount,
            BluxeStorage.BidTokenType previousBidTokenType
        ) = store.getHighestBid(listingId);

        BluxeStorage.Listing memory listing = store.getListing(listingId);

        if (!listing.active) {
            revert _ListingIsNotActive(listing.tokenId);
        }

        /// @notice Ensure that the listing is in auction mode
        /// @dev Only listings marked as `auction` can accept bids.
        ///      Prevents accidental ETH bids on fixed-price sales.
        if (!listing.auction) {
            revert _ListingIsNotInAuctionMode(listing.tokenId);
        }

        /// @notice Prevent the seller from bidding on their own auction
        /// Prevents conflicts of interest and maintains auction fairness.
        if (msg.sender == listing.seller) {
            revert SellerCannotBidOnOwnAuction(listing.tokenId);
        }

        /// @dev Ensure bid is within auction period and listing is active
        if (block.timestamp >= listing.auctionEndTime) {
            revert AuctionEnded(listing.tokenId);
        }

        /// @notice Ensure the bid respects the minimum increment rules
        /// @dev The minimum bid must exceed the current highest bid (or listing price if first bid)
        ///      by at least the greater of:
        ///       1) A percentage of the current highest bid (BID_INCREMENT_BPS)
        ///       2) A fixed absolute minimum (MIN_INCREMENT)
        ///
        ///      This prevents micro-bidding and ensures meaningful auction progression.
        /// @param listing The listing struct containing the NFT and starting price
        /// @param tokenId The token ID being bid on
        /// @param amount The bid amount submitted by the bidder

        uint256 current = previousHighestBidAmount == 0
            ? listing.price // first bid uses listing price as base
            : previousHighestBidAmount; // otherwise, current highest bid

        /// @notice Calculate minimum increment based on percentage
        uint256 minIncrement = (current * BID_INCREMENT_BPS) / 10_000;

        /// @notice Ensure minimum increment respects absolute minimum
        uint256 effectiveIncrement = minIncrement < MIN_INCREMENT ? MIN_INCREMENT : minIncrement;

        /// @notice Minimum bid required = current + effectiveIncrement
        uint256 minBidAmount = current + effectiveIncrement;

        /// @notice Implements last-minute auction extension to prevent sniping.
        /// @dev If a bid is placed within the final `EXTENSION_WINDOW` seconds of the auction,
        ///      the auction end time is extended by `EXTENSION_DURATION` seconds.
        ///      This ensures fair opportunity for other bidders and mitigates sniping.
        /// @param listing The auction listing being bid on.
        /// @param block.timestamp Current blockchain timestamp used to calculate time remaining.
        uint256 timeLeft = listing.auctionEndTime > block.timestamp
            ? listing.auctionEndTime - block.timestamp
            : 0;

        /// gas Safe
        uint256 _auctionEndTime = listing.auctionEndTime;

        if (msg.sender == previousHighestBidder) {
            if (msg.value == 0) revert ZeroBid();
            ///  prevent token switching
            if (previousBidTokenType != BluxeStorage.BidTokenType.ETH) {
                revert CannotChangeBidTokenType();
            }

            uint256 newTotalBid = msg.value + previousHighestBidAmount;
            if (newTotalBid < minBidAmount) {
                revert MustIncreaseYourOwnBid(minBidAmount);
            }

            store.setHighestBid(listingId, msg.sender, newTotalBid, BluxeStorage.BidTokenType.ETH);

            if (timeLeft < EXTENSION_WINDOW) {
                store.setAuctionEndTime(listingId, _auctionEndTime + EXTENSION_DURATION);
            }
            /// @dev Forward ETH immediately to Marketplace
            (bool ok, ) = payable(store.marketplace()).call{value: msg.value}("");
            if (!ok) revert _EthForwardFailed();

            emit BidPlaced(
                listing.nftContract,
                listing.tokenId,
                listing.seller,
                msg.sender,
                newTotalBid,
                BluxeStorage.BidTokenType.ETH,
                listingId
            );
            return;
        }

        /// @notice Revert if bid is below required threshold for new bidders
        if (msg.value < minBidAmount) {
            revert BidAmountMustExceedCurrentPrice(minBidAmount);
        }

        /// Refund the previous highest bidder via pending withdrawals (if any)

        if (previousHighestBidder != address(0) && previousHighestBidAmount > 0) {
            if (previousBidTokenType == BluxeStorage.BidTokenType.ETH) {
                store.addPendingETH(previousHighestBidder, previousHighestBidAmount);
            } else {
                store.addPendingWETH(previousHighestBidder, previousHighestBidAmount);
            }
        }

        /// @notice Update highest bid and safely refund previous highest bidder
        store.setHighestBid(listingId, msg.sender, msg.value, BluxeStorage.BidTokenType.ETH);

        // Auction extension if within last EXTENSION_WINDOW
        if (timeLeft < EXTENSION_WINDOW) {
            store.setAuctionEndTime(listingId, _auctionEndTime + EXTENSION_DURATION);
        }

        /// @dev Forward ETH immediately to Marketplace
        (bool ok, ) = payable(store.marketplace()).call{value: msg.value}("");
        if (!ok) revert _EthForwardFailed();
        emit BidPlaced(
            listing.nftContract,
            listing.tokenId,
            listing.seller,
            msg.sender,
            msg.value,
            BluxeStorage.BidTokenType.ETH,
            listingId
        );
    }

    function placeBidWeth(uint256 listingId, uint256 amount) external nonReentrant {
        // Implementation for placing a WETH bid would go here

        /// @dev Previous highest bidder
        (
            address previousHighestBidder,
            uint256 previousHighestBidAmount,
            BluxeStorage.BidTokenType previousBidTokenType
        ) = store.getHighestBid(listingId);

        BluxeStorage.Listing memory listing = store.getListing(listingId);

        if (!listing.active) {
            revert _ListingIsNotActive(listing.tokenId);
        }

        /// @notice Ensure that the listing is in auction mode
        /// Only listings marked as `auction` can accept bids.
        ///      Prevents accidental wETH bids on fixed-price sales.
        if (!listing.auction) {
            revert _ListingIsNotInAuctionMode(listing.tokenId);
        }

        if (amount == 0) revert ZeroBid();

        /// @notice Prevent the seller from bidding on their own auction
        /// Prevents conflicts of interest and maintains auction fairness.
        if (msg.sender == listing.seller) {
            revert SellerCannotBidOnOwnAuction(listing.tokenId);
        }

        /// @dev Ensure bid is within auction period and listing is active
        if (block.timestamp >= listing.auctionEndTime) {
            revert AuctionEnded(listing.tokenId);
        }

        /// @notice Ensure the bid respects the minimum increment rules
        /// @dev The minimum bid must exceed the current highest bid (or listing price if first bid)
        ///      by at least the greater of:
        ///       1) A percentage of the current highest bid (BID_INCREMENT_BPS)
        ///       2) A fixed absolute minimum (MIN_INCREMENT)
        ///
        ///      This prevents micro-bidding and ensures meaningful auction progression.
        /// @param listing The listing struct containing the NFT and starting price
        /// @param tokenId The token ID being bid on
        /// @param amount The bid amount submitted by the bidder

        uint256 current = previousHighestBidAmount == 0
            ? listing.price // first bid uses listing price as base
            : previousHighestBidAmount; // otherwise, current highest bid

        /// @notice Calculate minimum increment based on percentage
        uint256 minIncrement = (current * BID_INCREMENT_BPS) / 10_000;

        /// @notice Ensure minimum increment respects absolute minimum
        uint256 effectiveIncrement = minIncrement < MIN_INCREMENT ? MIN_INCREMENT : minIncrement;

        /// @notice Minimum bid required = current + effectiveIncrement
        uint256 minBidAmount = current + effectiveIncrement;

        /// @notice Implements last-minute auction extension to prevent sniping.
        /// @dev If a bid is placed within the final `EXTENSION_WINDOW` seconds of the auction,
        ///      the auction end time is extended by `EXTENSION_DURATION` seconds.
        ///      This ensures fair opportunity for other bidders and mitigates sniping.
        /// @param listing The auction listing being bid on.
        /// @param block.timestamp Current blockchain timestamp used to calculate time remaining.

        uint256 timeLeft = listing.auctionEndTime > block.timestamp
            ? listing.auctionEndTime - block.timestamp
            : 0;

        /// Safe gas
        uint256 _auctionEndTime = listing.auctionEndTime;

        if (msg.sender == previousHighestBidder) {
            //  prevent token switching
            if (previousBidTokenType != BluxeStorage.BidTokenType.WETH) {
                revert CannotChangeBidTokenType();
            }

            // Must strictly increase own bid
            if (amount <= previousHighestBidAmount) {
                revert MustIncreaseYourOwnBid(minBidAmount);
            }

            // Must satisfy auction increment rules
            if (amount < minBidAmount) {
                revert MustIncreaseYourOwnBid(minBidAmount);
            }

            uint256 delta = amount - previousHighestBidAmount;
            IERC20(store.weth()).safeTransferFrom(msg.sender, address(store.marketplace()), delta);

            store.setHighestBid(listingId, msg.sender, amount, BluxeStorage.BidTokenType.WETH);

            if (timeLeft < EXTENSION_WINDOW) {
                store.setAuctionEndTime(listingId, _auctionEndTime + EXTENSION_DURATION);
            }
            emit BidPlaced(
                listing.nftContract,
                listing.tokenId,
                listing.seller,
                msg.sender,
                amount,
                BluxeStorage.BidTokenType.WETH,
                listingId
            );
            return;
        }

        /// @notice Revert if bid is below required threshold for new bidders
        if (amount < minBidAmount) {
            revert BidAmountMustExceedCurrentPrice(minBidAmount);
        }

        IERC20(store.weth()).safeTransferFrom(msg.sender, address(store.marketplace()), amount);
        /// Refund the previous highest bidder via pending withdrawals (if any)

        if (previousHighestBidder != address(0) && previousHighestBidAmount > 0) {
            if (previousBidTokenType == BluxeStorage.BidTokenType.ETH) {
                store.addPendingETH(previousHighestBidder, previousHighestBidAmount);
            } else {
                store.addPendingWETH(previousHighestBidder, previousHighestBidAmount);
            }
        }

        /// @notice Update highest bid and safely refund previous highest bidder
        store.setHighestBid(listingId, msg.sender, amount, BluxeStorage.BidTokenType.WETH);

        // Auction extension if within last EXTENSION_WINDOW
        if (timeLeft < EXTENSION_WINDOW) {
            store.setAuctionEndTime(listingId, _auctionEndTime + EXTENSION_DURATION);
        }
        emit BidPlaced(
            listing.nftContract,
            listing.tokenId,
            listing.seller,
            msg.sender,
            amount,
            BluxeStorage.BidTokenType.WETH,
            listingId
        );
    }

    /// @notice Retrieve the highest bid for a given NFT
    function getHighestBid(
        uint256 listingId
    ) external view returns (address, uint256, BluxeStorage.BidTokenType) {
        (address bidder, uint256 amount, BluxeStorage.BidTokenType tokenType) = store.getHighestBid(
            listingId
        );
        return (bidder, amount, tokenType);
    }

    function resolveAuction(
        uint256 listingId
    )
        external
        nonReentrant
        onlyMarketplace
        returns (address winner, uint256 amount, BluxeStorage.BidTokenType t)
    {
        //---------- Implementation for finalizing the auction ----------

        BluxeStorage.Listing memory listing = store.getListing(listingId);

        /// @notice Ensure that @param tokenId is in auction mode
        if (!listing.auction) {
            revert _ListingIsNotInAuctionMode(listing.tokenId);
        }

        /// @notice Ensure Listing is still active
        if (!listing.active) {
            revert _ListingIsNotActive(listing.tokenId);
        }

        /// @dev Ensure seller cannot finalize Auction before auction end time
        if (block.timestamp < listing.auctionEndTime) {
            revert _AuctionNotEndedYet(listing.tokenId);
        }

        /// @notice Get highest bid details
        (
            address winningBidder,
            uint256 winningBidAmount,
            BluxeStorage.BidTokenType winningBidTokenType
        ) = store.getHighestBid(listingId);

        // ---- finalize state FIRST ----
        /// @dev listing is now → false
        store.setListingActive(listingId, false);
        /// Mark Bid as finalized by resetting highest bid data
        store.setHighestBid(listingId, address(0), 0, BluxeStorage.BidTokenType.NONE);

        emit AuctionResolved(
            listing.nftContract,
            listing.tokenId,
            listingId,
            winningBidAmount,
            listing.seller,
            winningBidder
        );
        return (winningBidder, winningBidAmount, winningBidTokenType);
    }

    /// @notice Handles payouts for a finalized auction or bid
    /// @dev Pays out the platform fee, royalties (if supported via ERC-2981), and the seller's share.
    ///      All amounts are credited as pending withdrawals in the storage contract (ETH or WETH) rather than sent immediately.
    ///      Ensures that the total paid (platform fee + royalty + seller amount) never exceeds the sale price.
    ///      If the NFT has no royalties or the royalty amount exceeds the remaining sale amount after platform fee, the royalty is capped.
    /// @param listing The listing struct containing NFT information, seller, and price
    /// @param amount The winning bid amount for this auction/listing
    /// @param winningBidTokenType The token type used for the winning bid (ETH or WETH)
    /// @custom:access Only callable by the Marketplace contract

    function handleBidPayouts(
        BluxeStorage.Listing memory listing,
        uint256 amount,
        BluxeStorage.BidTokenType winningBidTokenType
    ) external onlyMarketplace {
        uint256 salePrice = amount;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);

        (uint96 platformFeeBps, address platformFeeRecipient) = store.getPlatformDetails();

        /// @notice Handle royalties if applicable
        try IERC2981(listing.nftContract).royaltyInfo(listing.tokenId, salePrice) returns (
            address receiver,
            uint256 royaltyAmountCalculated
        ) {
            royaltyReceiver = receiver;
            royaltyAmount = royaltyAmountCalculated;
        } catch {
            // No royalties for this NFT
            royaltyAmount = 0;
            royaltyReceiver = address(0);
        }
        /// @dev Calculate MARKETPLACE fee
        uint256 platformFee = (salePrice * platformFeeBps) / 10000;

        /// compute royalty to pay but cap so (platformFee + royaltyToPay) <= salePrice
        uint256 sellerAmount = 0;
        uint256 royaltyToPay = 0;

        /// @notice If the platform fee >= sale price, the platform takes everything, and neither seller nor royalty get paid
        /// @notice Otherwise, pay royalties (if any), then platform fee, and finally the remaining to the seller
        /// @notice ETH or WETH payouts are handled depending on `winningBidTokenType`

        if (platformFee >= salePrice) {
            /// platform takes all, no royalty or seller amount
            sellerAmount = 0;
            royaltyToPay = 0;

            if (winningBidTokenType == BluxeStorage.BidTokenType.ETH) {
                /// for ETH: credit pendingWithdrawals (ETH)
                store.addPendingETH(platformFeeRecipient, platformFee);
            } else {
                /// for WETH: credit pendingWethWithdrawals (WETH)
                store.addPendingWETH(platformFeeRecipient, platformFee);
            }
            // Seller & royalty get nothing
        } else {
            uint256 maxRoyaltyPossible = salePrice - platformFee;
            if (royaltyReceiver != address(0) && royaltyAmount > 0) {
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
                 * - @notice Ensure:
                 *      Contract NEVER pay more royalty than what is realistically possible.
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
                    if (winningBidTokenType == BluxeStorage.BidTokenType.ETH) {
                        /// for ETH: credit pendingWithdrawals (ETH)
                        store.addPendingETH(royaltyReceiver, royaltyToPay);
                    } else {
                        /// for WETH: credit pendingWethWithdrawals (WETH)
                        store.addPendingWETH(royaltyReceiver, royaltyToPay);
                    }
                }
            }

            /// amount to seller
            sellerAmount = salePrice - platformFee - royaltyToPay;

            if (platformFee > 0) {
                if (winningBidTokenType == BluxeStorage.BidTokenType.ETH) {
                    /// for ETH: credit pendingWithdrawals (ETH)
                    store.addPendingETH(platformFeeRecipient, platformFee);
                } else {
                    /// for WETH: credit pendingWethWithdrawals (WETH)
                    store.addPendingWETH(platformFeeRecipient, platformFee);
                }
            }

            if (sellerAmount > 0) {
                if (winningBidTokenType == BluxeStorage.BidTokenType.ETH) {
                    /// for ETH: credit pendingWithdrawals (ETH)
                    store.addPendingETH(listing.seller, sellerAmount);
                } else {
                    /// for WETH: credit pendingWethWithdrawals (WETH)
                    store.addPendingWETH(listing.seller, sellerAmount);
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

    receive() external payable {
        revert("NO_DIRECT_ETH");
    }
}

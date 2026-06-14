// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title BluxeStorage
/// @author Izaq dev
/// @custom:github https://github.com/0xSmartCoder
/// @custom:linkedin https://www.linkedin.com/in/izaq-b8674233a

/// @notice Centralized storage contract for Bluxe Marketplace (Diamond-style storage)
/// @dev ONLY authorized logic contracts can mutate state

import "@openzeppelin/contracts/interfaces/IERC2981.sol";
/// @dev custom Error
error InsufficientFunds(uint256);
error InvalidListingKey();
error ZeroAddress();
error InvalidFee();
error NotOwner();
error AuctionAlreadyFinalized(uint256);
error InvalidAuctionResult();

contract BluxeStorage {
    /*//////////////////////////////////////////////////////////////
                              EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event TransferOwnershipRequested(uint256 id, address from, address _to);
    event AuthorizeUpdated(address indexed addr, bool status);
    event ListingUpdates(
        address indexed nft,
        uint256 indexed tokenId,
        address indexed seller,
        uint256 price,
        bool isAuction
    );
    event BidUpdates(
        address indexed nft,
        uint256 indexed tokenId,
        uint256 bidAmount,
        address bidder
    );
    event OfferUpdates(uint256 indexed listingId, uint256 offerAmount, address offerer);
    event PendingWithdrawalReduced(address sender, uint256 amount);
    event PlatformFeeUpdated(address newRecipient, uint256 fee);
    event AdminApproved(address from, uint256 atId);
    event Payout(
        address seller,
        uint sellerAmount,
        address royaltyReceiver,
        uint royalty,
        address platform,
        uint fee
    );

    /*//////////////////////////////////////////////////////////////
                              ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized(address caller);
    error BAD_OWNER();
    error OnlyForAdmins();
    error NotActive();
    error AlreadyExecutes();
    error YouAlreadyApproved();
    error RequestExpired();
    error MustApprovedByTwoAdmins();
    error InvalidRequest();
    error PreviousRequestStillActive();
    error DuplicateAdmin(address);
    error NoAdmins();

    /*//////////////////////////////////////////////////////////////
                          ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public weth;
    address public marketplace;
    address public bidManager;
    address public offerManager;
    address[] public admins;
    uint256 public requestId = 0;

    struct Request {
        uint256 approval;
        address to;
        bool active;
        bool successfullyTransferred;
        uint256 expiry;
    }

    mapping(address => bool) public authorized;
    mapping(uint256 => Request) public requests;
    mapping(uint256 => mapping(address => bool)) public hasApproved;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyAuthorized() {
        if (!authorized[msg.sender] && msg.sender != owner) {
            revert NotAuthorized(msg.sender);
        }
        _;
    }

    constructor(address[] memory _admins) {
        owner = msg.sender;
        if (_admins.length == 0) revert NoAdmins();
        for (uint256 i = 0; i < _admins.length; i++) {
            address admin = _admins[i];
            if (_admins[i].code.length > 0) revert BAD_OWNER();
            if (msg.sender == _admins[i]) revert BAD_OWNER();

            for (uint j = 0; j < i; j++) {
                if (_admins[j] == admin) {
                    revert DuplicateAdmin(admin);
                }
            }
            admins.push(_admins[i]);
        }
    }

    function setAuthorized(address addr, bool status) external onlyOwner {
        authorized[addr] = status;
        emit AuthorizeUpdated(addr, status);
    }

    function transferOwnershipRequest(address newOwner) external onlyOwner returns (uint256) {
        if (requestId > 0 && requests[requestId - 1].active) {
            revert PreviousRequestStillActive();
        }
        if (newOwner == address(0)) {
            revert ZeroAddress();
        }
        requests[requestId] = Request({
            approval: 0,
            to: newOwner,
            active: true,
            successfullyTransferred: false,
            expiry: block.timestamp + 30 minutes
        });

        uint256 currentId = requestId;
        requestId++;
        emit TransferOwnershipRequested(currentId, msg.sender, newOwner);
        return currentId;
    }

    function approve(uint256 id) external {
        if (hasApproved[id][msg.sender]) {
            revert YouAlreadyApproved();
        }

        if (requests[id].to == address(0)) revert InvalidRequest();

        Request memory _r = requests[id];

        if (block.timestamp > _r.expiry) {
            revert RequestExpired();
        }
        if (!_r.active) {
            revert NotActive();
        }
        if (_r.successfullyTransferred) {
            revert AlreadyExecutes();
        }

        bool isAdmin = false;
        for (uint256 i = 0; i < admins.length; i++) {
            if (msg.sender == admins[i]) {
                isAdmin = true;
                break;
            }
        }

        if (!isAdmin) revert OnlyForAdmins();
        hasApproved[id][msg.sender] = true;
        requests[id].approval++;

        emit AdminApproved(msg.sender, id);
    }

    function execute(uint256 id) external onlyOwner {
        if (requests[id].to == address(0)) revert InvalidRequest();

        Request memory _r = requests[id];

        uint256 requirdApproval = (admins.length / 2) + 1;
        if (block.timestamp > _r.expiry) {
            revert RequestExpired();
        }
        if (!_r.active) {
            revert NotActive();
        }
        if (_r.successfullyTransferred) {
            revert AlreadyExecutes();
        }
        if (_r.approval < requirdApproval) {
            revert MustApprovedByTwoAdmins();
        }
        requests[id].successfullyTransferred = true;
        requests[id].active = false;
        owner = _r.to;

        emit OwnershipTransferred(msg.sender, _r.to);
    }
    function setWeth(address _weth) external onlyOwner {
        if (_weth == address(0)) {
            revert ZeroAddress();
        }
        weth = _weth;
    }
    function setMarketplace(address _marketplace) external onlyOwner {
        if (_marketplace == address(0)) {
            revert ZeroAddress();
        }
        marketplace = _marketplace;
    }
    function setBidManager(address _bidManager) external onlyOwner {
        if (_bidManager == address(0)) {
            revert ZeroAddress();
        }
        bidManager = _bidManager;
    }

    function setOfferManager(address _offerManager) external onlyOwner {
        if (_offerManager == address(0)) {
            revert ZeroAddress();
        }
        offerManager = _offerManager;
    }

    /*//////////////////////////////////////////////////////////////
                              TYPES
    //////////////////////////////////////////////////////////////*/

    /// fee & feeReceipient
    uint96 public platformFeeBps;
    address public platformFeeRecipient;
    enum BidTokenType {
        ETH,
        WETH,
        NONE
    }

    enum OfferTokenType {
        ETH,
        WETH,
        NONE
    }

    struct Listing {
        address nftContract;
        address seller;
        uint256 price;
        uint256 tokenId;
        bool active;
        bool auction;
        uint256 auctionEndTime;
    }

    struct HighestBid {
        address bidder;
        uint256 amount;
        BidTokenType tokenType;
    }

    struct Offer {
        uint256 amount;
        OfferTokenType tokenType;
    }

    struct TopOffer {
        address offerer;
        uint256 amount;
        OfferTokenType tokenType;
    }

    struct AuctionResult {
        address winner;
        uint256 amount;
        BidTokenType tokenType;
        bool claimed;
    }

    struct BlockNfts {
        uint256 listingId;
        bool status;
    }

    struct AcceptedOffer {
        address winner;
        uint256 amount;
        OfferTokenType tokenType;
        bool claimed;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/

    // Listings
    // listingId => Listing
    mapping(uint256 listingId => Listing) private _listings;

    // Offer system
    mapping(uint256 listingId => bool) private _offerRefundable;

    mapping(uint256 listingId => mapping(address => Offer)) private _offers;
    mapping(uint256 listingId => address[]) private _offerers;
    mapping(uint256 listingId => mapping(address => bool)) private _isOfferer;
    mapping(uint256 listingid => AcceptedOffer) private _acceptedOffer;

    // cached top Offer
    mapping(uint256 listingId => TopOffer) private _topOffer;

    // Bidding system
    mapping(uint256 listingId => HighestBid) private _highestBid;
    mapping(uint256 listingId => AuctionResult) private _auctionWinner;

    // Payments
    mapping(address => uint256) private pendingWithdrawalsETH;
    mapping(address => uint256) private pendingWithdrawalsWETH;

    // track block Nfts
    mapping(uint256 listingId => BlockNfts) private _blockNft;

    /*//////////////////////////////////////////////////////////////
                          LISTING GETTERS
    //////////////////////////////////////////////////////////////*/

    function getListing(uint256 listingId) external view returns (Listing memory) {
        return _listings[listingId];
    }

    /*//////////////////////////////////////////////////////////////
                          LISTING SETTERS
    //////////////////////////////////////////////////////////////*/
    function setListing(
        address nft,
        uint256 tokenId,
        uint256 listingId,
        Listing calldata l
    ) external onlyAuthorized {
        if (l.nftContract != nft) revert InvalidListingKey();
        if (l.tokenId != tokenId) revert InvalidListingKey();
        _listings[listingId] = l;
        emit ListingUpdates(nft, tokenId, l.seller, l.price, l.auction);
    }

    function setListingActive(uint256 listingId, bool active) external onlyAuthorized {
        _listings[listingId].active = active;
    }

    function getListingActive(uint256 listingId) public view returns (bool) {
        return _listings[listingId].active;
    }

    function setAuctionEndTime(uint256 listingId, uint256 newTimeStamp) external onlyAuthorized {
        _listings[listingId].auctionEndTime = newTimeStamp;
    }

    /*//////////////////////////////////////////////////////////////
                        OFFER REFUNDABLE / SETTERS & GETTER
    //////////////////////////////////////////////////////////////*/
    function setOfferRefundable(uint256 listingId, bool status) external onlyAuthorized {
        _offerRefundable[listingId] = status;
    }

    function isOfferRefundable(uint256 listingId) external view returns (bool) {
        return _offerRefundable[listingId];
    }

    /*//////////////////////////////////////////////////////////////
                        OFFER GETTERS / SETTERS
    //////////////////////////////////////////////////////////////*/
    function getOffer(
        uint256 listingId,
        address user
    ) external view returns (uint256, OfferTokenType) {
        Offer storage o = _offers[listingId][user];
        return (o.amount, o.tokenType);
    }

    function setOffer(
        uint256 listingId,
        address user,
        uint256 amount,
        OfferTokenType tokenType
    ) external onlyAuthorized {
        // set offer
        _offers[listingId][user] = Offer({amount: amount, tokenType: tokenType});

        // push offerer
        if (!_isOfferer[listingId][user]) {
            _offerers[listingId].push(user);
            _isOfferer[listingId][user] = true;
        }

        // updateTopOffer
        _updateTopOffer(listingId, user, amount, tokenType);

        emit OfferUpdates(listingId, amount, user);
    }

    function resetOfferAmountAndTokenType(
        uint256 listingId,
        address canceller
    ) external onlyAuthorized {
        _offers[listingId][canceller] = Offer({amount: 0, tokenType: OfferTokenType.NONE});
    }

    function _updateTopOffer(
        uint256 listingId,
        address user,
        uint256 amount,
        OfferTokenType tokenType
    ) internal {
        TopOffer storage top = _topOffer[listingId];

        if (amount > top.amount) {
            top.offerer = user;
            top.amount = amount;
            top.tokenType = tokenType;
        }
    }

    function setAcceptedOffer(
        uint256 listingId,
        address user,
        uint256 amount,
        OfferTokenType tokenType
    ) external onlyAuthorized {
        _acceptedOffer[listingId] = AcceptedOffer({
            winner: user,
            amount: amount,
            tokenType: tokenType,
            claimed: false
        });
    }

    function getAcceptedOffer(uint256 listingId) external view returns (AcceptedOffer memory) {
        return _acceptedOffer[listingId];
    }

    function markOfferClaimed(uint256 listingId) external onlyAuthorized {
        _acceptedOffer[listingId].claimed = true;
    }

    function getOfferClaimedStatus(uint256 listingId) external view returns (bool) {
        return _acceptedOffer[listingId].claimed;
    }

    function getIsOfferer(uint256 listingId, address user) external view returns (bool) {
        return _isOfferer[listingId][user];
    }

    function recomputeTopOffer(uint256 listingId) external onlyAuthorized {
        address[] storage arr = _offerers[listingId];

        address bestUser;
        uint256 bestAmount;
        OfferTokenType tokenType;

        for (uint256 i = 0; i < arr.length; i++) {
            Offer memory o = _offers[listingId][arr[i]];
            if (o.amount > bestAmount) {
                bestAmount = o.amount;
                bestUser = arr[i];
                tokenType = o.tokenType;
            }
        }

        if (bestAmount == 0) {
            delete _topOffer[listingId];
        } else {
            _topOffer[listingId] = TopOffer({
                offerer: bestUser,
                amount: bestAmount,
                tokenType: tokenType
            });
        }
    }

    function clearTopOffer(uint256 listingId) external onlyAuthorized {
        delete _topOffer[listingId];
    }

    function getOfferer(uint256 listingId) external view returns (address[] memory) {
        return _offerers[listingId];
    }

    function offerersLength(uint256 listingId) external view returns (uint256) {
        return _offerers[listingId].length;
    }

    function resetTopOfferAndOfferers(uint256 listingId) external onlyAuthorized {
        delete _topOffer[listingId];
        delete _offerers[listingId];
    }

    function clearisOfferer(uint256 listingId, address user) external onlyAuthorized {
        _isOfferer[listingId][user] = false;
    }
    function getTopOffer(
        uint256 listingId
    ) external view returns (address, uint256, OfferTokenType tokenType) {
        TopOffer storage t = _topOffer[listingId];
        return (t.offerer, t.amount, t.tokenType);
    }

    /*//////////////////////////////////////////////////////////////
                          BID GETTERS / SETTERS
    //////////////////////////////////////////////////////////////*/

    function setHighestBid(
        uint256 listingId,
        address bidder,
        uint256 amount,
        BidTokenType tokenType
    ) external onlyAuthorized {
        _highestBid[listingId] = HighestBid({bidder: bidder, amount: amount, tokenType: tokenType});
    }

    function getHighestBid(
        uint256 listingId
    ) external view returns (address bidder, uint256 amount, BidTokenType tokenType) {
        HighestBid memory hb = _highestBid[listingId];
        return (hb.bidder, hb.amount, hb.tokenType);
    }

    function setAuctionResult(
        uint256 listingId,
        address _winner,
        uint256 _amount,
        BidTokenType _tokenType
    ) external onlyAuthorized {
        if (_auctionWinner[listingId].winner != address(0)) {
            revert AuctionAlreadyFinalized(listingId);
        }

        if (
            (_winner != address(0) /* Winner exist */ &&
                _amount == 0 /* winner exist with zero amount! */) ||
            (_winner == address(0) /* Winner doesn't exist */ &&
                _amount != 0 /* winner doesn't exist but amount doesn't zero! */)
        ) {
            revert InvalidAuctionResult();
        }

        _auctionWinner[listingId] = AuctionResult({
            winner: _winner,
            amount: _amount,
            tokenType: _tokenType,
            claimed: false
        });
    }

    function getAuctionResult(uint256 listingId) external view returns (AuctionResult memory) {
        return _auctionWinner[listingId];
    }

    function markAuctionClaimed(uint256 listingId) external onlyAuthorized {
        _auctionWinner[listingId].claimed = true;
    }

    function getAuctionClaimedStatus(uint256 listingId) external view returns (bool) {
        return _auctionWinner[listingId].claimed;
    }

    /*//////////////////////////////////////////////////////////////
                          PENDING WITHDRAWAL GETTERS / SETTERS
    //////////////////////////////////////////////////////////////*/

    function addPendingETH(address user, uint256 amount) public onlyAuthorized {
        pendingWithdrawalsETH[user] += amount;
    }

    function getPendingETH(address user) external view returns (uint256) {
        return pendingWithdrawalsETH[user];
    }

    function clearPendingETH(address user) external onlyAuthorized {
        pendingWithdrawalsETH[user] = 0;
    }

    function subPendingETH(address user, uint256 amount) external onlyAuthorized {
        uint256 bal = pendingWithdrawalsETH[user];
        if (bal < amount) {
            revert InsufficientFunds(amount);
        }
        pendingWithdrawalsETH[user] = bal - amount;
        emit PendingWithdrawalReduced(user, amount);
    }

    function addPendingWETH(address user, uint256 amount) public onlyAuthorized {
        pendingWithdrawalsWETH[user] += amount;
    }

    function getPendingWETH(address user) external view returns (uint256) {
        return pendingWithdrawalsWETH[user];
    }

    function subPendingWETH(address user, uint256 amount) external onlyAuthorized {
        uint256 bal = pendingWithdrawalsWETH[user];
        if (bal < amount) {
            revert InsufficientFunds(amount);
        }
        pendingWithdrawalsWETH[user] = bal - amount;
        emit PendingWithdrawalReduced(user, amount);
    }

    function clearPendingWETH(address user) external onlyAuthorized {
        pendingWithdrawalsWETH[user] = 0;
    }

    /*//////////////////////////////////////////////////////////////
                            ONLY OWNER
    //////////////////////////////////////////////////////////////*/
    function updatePlatformDetails(address newRecipient, uint96 newFeeBps) external {
        if (msg.sender != owner && msg.sender != marketplace) {
            revert NotOwner();
        }
        if (newRecipient == address(0)) revert ZeroAddress();
        if (newFeeBps > 10_000) revert InvalidFee();
        platformFeeRecipient = newRecipient;
        platformFeeBps = newFeeBps;
        emit PlatformFeeUpdated(newRecipient, newFeeBps);
    }

    function getPlatformDetails() public view returns (uint96, address) {
        return (platformFeeBps, platformFeeRecipient);
    }

    /// block Nfts
    function markNFTBlocked(uint256 listingId, bool status) external onlyAuthorized {
        _blockNft[listingId] = BlockNfts({listingId: listingId, status: status});
    }

    /// --------------- Helper Function ---------------

    function handlePayouts(
        BluxeStorage.Listing memory listing,
        BluxeStorage.BidTokenType tokenType
    ) external onlyAuthorized {
        uint salePrice = listing.price;
        uint256 royaltyAmount = 0;
        address royaltyReceiver = address(0);

        (uint96 platformFeeBps, address platformFeeRecipient) = getPlatformDetails();

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
        /// calculate platform fee
        uint256 platformFee = (salePrice * platformFeeBps) / 10_000;

        /// compute royalty to pay but cap so (platformFee + royaltyToPay) <= salePrice
        uint256 sellerAmount = 0;
        uint256 royaltyToPay = 0;

        if (platformFee >= salePrice) {
            /// platform takes all; no royalty or seller amount
            sellerAmount = 0;
            royaltyToPay = 0;
            _addPending(platformFeeRecipient, salePrice, tokenType);
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
                    _addPending(royaltyReceiver, royaltyToPay, tokenType);
                }
            }

            /// pay platform fee
            if (platformFee > 0) {
                _addPending(platformFeeRecipient, platformFee, tokenType);
            }
            /// remaining to the seller
            sellerAmount = salePrice - platformFee - royaltyToPay;
            // pay seller
            if (sellerAmount > 0) {
                _addPending(listing.seller, sellerAmount, tokenType);
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
    function _addPending(address to, uint256 amount, BidTokenType t) internal {
        if (t == BluxeStorage.BidTokenType.ETH) addPendingETH(to, amount);
        else if (t == BluxeStorage.BidTokenType.WETH) addPendingWETH(to, amount);
    }
}

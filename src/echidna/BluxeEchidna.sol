// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.28;

// import "../BluxeOfferManager.sol";
// import "../BluxeBidManager.sol";
// import "../BluxeMarketplace.sol";
// import "../BluxeStorage.sol";
// import "../BluxeToken.sol";
// import "../MockWeth.sol";
// import "../EvilERC2981.sol";

// contract EchidnaTest {
//     BluxeMarketplace bluxeMarketplace;
//     BluxeBidManager bidContract;
//     BluxeStorage bluxeStorage;
//     BluxeOfferManager offerContract;
//     Bluxe bluxe;
//     FakeWETH weth;
//     EvilNFT evilNft;

//     address[] public _admins;
//     address[] public _users;
//     uint256 public nextTokenId;
//     uint256 public totalETHIn;

//     receive() external payable {}
//     constructor() payable {
//         _admins.push(address(11));
//         _admins.push(address(12));
//         _admins.push(address(13));

//         _users.push(address(0x1000000000000000000000000000000000000001));
//         _users.push(address(0x2000000000000000000000000000000000000002));
//         _users.push(address(0x3000000000000000000000000000000000000003));
//         _users.push(address(0x1000000000000000000000000000000000000004));
//         _users.push(address(0x5000000000000000000000000000000000000005));
//         _users.push(address(0x6000000000000000000000000000000000000006));

//         bluxeStorage = new BluxeStorage(_admins);
//         evilNft = new EvilNFT();
//         bluxe = new Bluxe("", "", address(this), 500, address(this));

//         bidContract = new BluxeBidManager(address(bluxeStorage));
//         bluxeStorage.setBidManager(address(bidContract));

//         offerContract = new BluxeOfferManager(address(bluxeStorage));
//         bluxeStorage.setOfferManager(address(offerContract));

//         bluxeMarketplace = new BluxeMarketplace(address(bluxeStorage));
//         bluxeStorage.setMarketplace(address(bluxeMarketplace));
//         weth = new FakeWETH();

//         bluxeStorage.setAuthorized(address(bluxeMarketplace), true);
//         bluxeStorage.setAuthorized(address(bidContract), true);
//         bluxeStorage.setWeth(address(weth));
//         bluxeStorage.setAuthorized(address(address(this)), true);
//     }

//     function _sumPendingETH() internal view returns (uint256 total) {
//         for (uint256 i = 0; i < _users.length; i++) {
//             total += bluxeStorage.getPendingETH(_users[i]);
//         }
//         total += bluxeStorage.getPendingETH(bluxeStorage.platformFeeRecipient());
//         total += bluxeStorage.getPendingETH(address(this));
//         return total;
//     }

//     function action_create_evil_listing(uint256 price) public {
//         price = price % 10 ether;
//         if (price == 0) price = 1 wei;

//         evilNft.mint(address(this), nextTokenId);
//         evilNft.approve(address(bluxeMarketplace), nextTokenId);

//         bluxeMarketplace.createListing(address(evilNft), nextTokenId, price, false, 0);

//         nextTokenId++;
//     }

//     function action_create_listing(uint256 price, bool auction) public {
//         price = price % 1000 ether;
//         if (price == 0) price = 1 wei;
//         bluxe.mint("", "", "", address(this));
//         uint256 tokenId = nextTokenId++;
//         bluxe.approve(address(bluxeMarketplace), tokenId);

//         uint256 time = auction ? block.timestamp + 1 days : 0;
//         bluxeMarketplace.createListing(address(bluxe), tokenId, price, auction, time);
//     }
//     function action_place_bid(uint256 listingId) public payable {
//         uint256 max = bluxeMarketplace.nextListingId();
//         if (max == 0) return;

//         listingId = listingId % max;

//         bidContract.placeBidEth{ value: msg.value }(listingId);
//     }

//     function action_buy(uint256 listingId) public payable {
//         uint256 max = bluxeMarketplace.nextListingId();
//         if (max == 0) return;

//         listingId = listingId % max;
//         totalETHIn += msg.value;
//         bluxeMarketplace.buyItemWithEth{ value: msg.value }(listingId);
//     }

//     /// 1️⃣ Marketplace should never lose ETH accounting
//     function echidna_eth_balance_consistent() public view returns (bool) {
//         uint256 pendingETH = _sumPendingETH();

//         return address(bluxeMarketplace).balance >= pendingETH;
//     }

//     /// 2️⃣ No listing should have zero price
//     function echidna_listing_price_gt_zero() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         for (uint256 i = 1; i <= total; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (l.seller != address(0)) {
//                 if (l.price == 0) return false;
//             }
//         }
//         return true;
//     }

//     /// 3️⃣ Highest bid must always be >= bid starting price
//     function echidna_highest_bid_monotonic() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         uint256 totalListings = total - 1;
//         for (uint256 i = 0; i <= totalListings; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);

//             // skip invalid / inactive listings
//             if (l.seller == address(0)) continue;
//             if (!l.auction) continue;

//             (, uint256 highestBid, ) = bluxeStorage.getHighestBid(i);
//             // no bids yet → allowed
//             if (highestBid == 0) continue;
//             if (highestBid < l.price) {
//                 return false;
//             }
//         }
//         return true;
//     }

//     /// 4️⃣ Seller can never be zero for active listings
//     function echidna_valid_seller() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         uint256 totalListings = total - 1;
//         for (uint256 i = 1; i <= totalListings; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (l.active && l.seller == address(0)) return false;
//         }
//         return true;
//     }

//     /// 5️⃣ Marketplace should never hold NFTs permanently
//     function echidna_no_stuck_nft() public view returns (bool) {
//         for (uint i = 1; i < bluxeMarketplace.nextListingId(); i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (!l.active) {
//                 if (bluxe.ownerOf(l.tokenId) == address(bluxeMarketplace)) {
//                     return false;
//                 }
//             }
//         }
//         return true;
//     }

//     function echidna_payout_never_exceeds_price() public view returns (bool) {
//         return address(bluxeMarketplace).balance <= totalETHIn;
//     }

//     function action_call_evil_payout() public {
//         BluxeStorage.Listing memory l;
//         l.nftContract = address(evilNft);
//         l.price = 0.2 ether;

//         bluxeStorage.handlePayouts(l, BluxeStorage.BidTokenType.ETH);
//     }

//     function echidna_evil_erc2981() public returns (bool) {
//         BluxeStorage.Listing memory l;
//         l.nftContract = address(evilNft);
//         l.price = 0.2 ether;

//         try bluxeStorage.handlePayouts(l, BluxeStorage.BidTokenType.ETH) {
//             // if EvilERC2981 didn't brick us → GOOD
//             return true;
//         } catch {
//             // revert means marketplace is vulnerable
//             return false;
//         }
//     }

//     function echidna_bid_refunds_never_lost() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         for (uint256 i = 1; i < total; i++) {
//             (, uint256 highestBid, ) = bluxeStorage.getHighestBid(i);
//             if (highestBid > 0) {
//                 // kisi na kisi ke pendingETH me refund hona chahiye
//                 if (_sumPendingETH() == 0) return false;
//             }
//         }
//         return true;
//     }

//     function echidna_no_bid_after_auction_end() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         for (uint256 i = 1; i < total; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (l.auction && block.timestamp > l.auctionEndTime) {
//                 (, uint256 highestBid, ) = bluxeStorage.getHighestBid(i);
//                 if (highestBid > l.price) {
//                     // if any Bid, auction logic broken
//                     return false;
//                 }
//             }
//         }
//         return true;
//     }

//     function echidna_seller_never_buys_own_listing() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         for (uint256 i = 1; i < total; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (!l.active) continue;

//             if (l.seller == address(this)) {
//                 // agar marketplace ke paas NFT aa jaye → bug
//                 if (bluxe.ownerOf(l.tokenId) == address(this)) {
//                     return false;
//                 }
//             }
//         }
//         return true;
//     }

//     function echidna_listing_storage_integrity() public view returns (bool) {
//         uint256 total = bluxeMarketplace.nextListingId();
//         for (uint256 i = 1; i < total; i++) {
//             BluxeStorage.Listing memory l = bluxeStorage.getListing(i);
//             if (l.seller == address(0)) {
//                 if (l.price != 0 || l.active) return false;
//             }
//         }
//         return true;
//     }
// }

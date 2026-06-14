// SPDX-License-Identifier: M.I.T
pragma solidity ^0.8.28;
import {BluxeMarketplace} from "../src/BluxeMarketplace.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Test} from "forge-std/Test.sol";
import {BluxeToken} from "../src/BluxeToken.sol";
import {BluxeOfferManager} from "../src/BluxeOfferManager.sol";
import {BluxeStorage} from "../src/BluxeStorage.sol";
import {console} from "lib/forge-std/src/console.sol";

contract bluxeTest is Test, IERC721Receiver {
    BluxeMarketplace public Bluxe;
    BluxeStorage public bluxeStorage;
    BluxeOfferManager public offerManager;
    BluxeToken public bluxeToken;

    //  STATE VARIABLES
    uint256 public listingPrice = 0.5 ether;
    address public fakeUser = address(0xe3eee);
    address public dummyAd = makeAddr("dummyAdmin");
    address[] public dummyAdmin;

    // EVENTS
    event Listed(
        address nftContract,
        address indexed seller,
        uint256 indexed price,
        uint256 indexed tokenId,
        uint256 listingId
    );
    event WithdrawnETH(address indexed caller, uint256 amount);
    event PlatformFeeUpdated(uint256 indexed newPrice, address indexed newReceipient);
    function setUp() public {
        dummyAdmin.push(dummyAd);
        bluxeStorage = new BluxeStorage(dummyAdmin);

        offerManager = new BluxeOfferManager(address(bluxeStorage));
        Bluxe = new BluxeMarketplace(address(bluxeStorage)); // 3.5% fee

        // Give Permissions...
        bluxeStorage.setMarketplace(address(Bluxe));
        bluxeStorage.setOfferManager(address(offerManager));
        bluxeStorage.setAuthorized(address(offerManager), true);
        bluxeStorage.setAuthorized(address(Bluxe), true);

        // set Platform fee & receiver
        bluxeStorage.updatePlatformDetails(msg.sender, 350);

        bluxeToken = new BluxeToken("", "", msg.sender, 500, msg.sender);
        // mint
        bluxeToken.mint("", "", "", address(this));
        assert(bluxeToken.getNextTokenID() == 1);
        bluxeToken.approve(address(Bluxe), 0);
        vm.expectEmit(true, true, true, true);
        emit Listed(address(bluxeToken), address(this), listingPrice, 0, 0);
        Bluxe.createListing(address(bluxeToken), 0, listingPrice, false, 0);
    }

    // -----------------Create Listing----------------- //

    function testCreateListing() public {
        // it should be revert() => reason(amount <= 0)
        vm.expectRevert();
        uint8 zero_Eth = 0 ether;
        Bluxe.createListing(address(bluxeToken), 0, zero_Eth, false, 0);

        // it should also revert() => reason(Invalid token owner)
        vm.startPrank(fakeUser);
        vm.expectRevert();
        Bluxe.createListing(address(bluxeToken), 0, listingPrice, false, 0);
        vm.stopPrank();

        // next Listing Id should be now: 1
        assertEq(Bluxe.nextListingId(), 1);

        // Nft transfered from seller to MarketPlace for escrow
        assertEq(bluxeToken.ownerOf(0), address(Bluxe));
        assert(bluxeToken.ownerOf(0) != address(0));
    }

    // -----------------Cancel Listing----------------- //

    function testCancelListing() public {
        // it will revert() => reason(Not Your Listing)
        vm.startPrank(fakeUser);
        vm.expectRevert();
        Bluxe.cancelListing(0);
        vm.stopPrank();
        assert(bluxeStorage.getListing(0).active == true);

        // try to cancel a non-active item
        bluxeToken.mint("", "", "", address(bluxeToken));
        vm.expectRevert();
        Bluxe.cancelListing(1);

        // cancel the listing and check status
        Bluxe.cancelListing(0);
        // Listing was cancelled, now ownerOf(0) is Nft was transferFrom address(this) => (msg.sender)
        // status should be false now!
        assert(bluxeStorage.getListing(0).active == false);
        // Not marketplace
        assert(bluxeToken.ownerOf(0) != address(Bluxe));
        assertEq(bluxeToken.ownerOf(0), address(this));
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // -----------------Burn Token----------------- //

    function testBurn() public {
        // cancel Listing first
        Bluxe.cancelListing(0);
        // verify owner
        assertEq(bluxeToken.ownerOf(0), address(this));
        // try to burn without approval!
        vm.expectRevert();
        bluxeToken.burn(0);
        // now take approval & burn and check ownerOf(0) = ?
        bluxeToken.approveBurn(address(this), 0);
        // it should be true, because we now have an approval
        assert(bluxeToken.approveBurn(address(this), 0) == true);
        bluxeToken.burn(0);
        vm.expectRevert();
        bluxeToken.ownerOf(0);
    }

    // -----------------Buy Item----------------- //

    function testBuy() public {
        // try to buy non-active item
        bluxeToken.mint("", "", "", address(this));
        vm.expectRevert();
        Bluxe.buyItemWithEth{value: 0.2 ether}(1);
        // verify listing status of tokenId 1
        // it should be false and seller = address(0), reason => it's not listed
        assert(bluxeStorage.getListing(1).active == false);
        assert(bluxeStorage.getListing(1).seller == address(0));

        // it will revert() because we don't send enough eth
        vm.expectRevert();
        Bluxe.buyItemWithEth{value: 0.2 ether}(0);
        // send msg.value > Listing Price, pendingWithdraw should be updated for buyer because amount > listing price
        // prank as fakeUser because we cannot buy our own listing
        vm.deal(fakeUser, 1 ether);
        vm.prank(fakeUser);
        Bluxe.buyItemWithEth{value: 1 ether}(0);
        assert(bluxeStorage.getPendingETH(fakeUser) == 0.5 ether);

        // Listing should be inactive now
        assert(bluxeStorage.getListing(0).active == false);
        // Nft owner should be buyer now
        assertEq(bluxeToken.ownerOf(0), fakeUser);

        // Royalty check
        (address r1, uint256 a1) = bluxeToken.royaltyInfo(0, listingPrice);

        assertEq(r1, msg.sender);
        assertEq(a1, (listingPrice * 500) / 10000); // 500 bps = 5%
        // royalty received: 0.025 + platform fee: 0.0175 = 0.0425
        uint256 marketplacefee = (listingPrice * 350) / 10000; // 350 bps = 3.5%
        assertEq(bluxeStorage.getPendingETH(r1), a1 + marketplacefee);

        // Proof marketplace fee
        // Marketplace fee = 3.5% of listing price
        // Here Owner & Royalty receiver is msg.sender & Seller is address(this)
        uint256 totalAmount_Of_Owner_And_RoyaltyReceiver = /* Royalty received amount (Royalty receiver) */ a1 +
                /* Marketplace fee goes to Owner msg.sender */ marketplacefee;
        assertEq(bluxeStorage.getPendingETH(msg.sender), totalAmount_Of_Owner_And_RoyaltyReceiver);

        // Seller proceed check
        // Sale Price 0.5 - Marketplace fee 0.025 - Royalty to pay 0.0175 = 0.4575
        uint256 sellerProceed = listingPrice - a1 - marketplacefee;
        assertEq(bluxeStorage.getPendingETH(address(this)), sellerProceed);

        // Now Nft was transfered to buyer
        assert(bluxeToken.ownerOf(0) == fakeUser);
    }

    // -----------------Make Offer----------------- //

    function testMakeOffer() public {
        // we will buying tokenId(0) first to make offer tests more realistic and verify that offer cannot be made on non-active listing
        vm.deal(fakeUser, 4 ether);
        vm.prank(fakeUser);
        Bluxe.buyItemWithEth{value: 1 ether}(0);

        // now mint another tokenId(1) to address(this) for making listing
        bluxeToken.mint("", "", "", address(this));

        // Make offer with zero eth
        vm.startPrank(fakeUser);
        vm.expectRevert();
        // try to offer with 0 eth
        offerManager.makeOfferEth{value: 0 ether}(0);
        vm.expectRevert();
        // this offer will be failed because tokenId(0) was already sold above
        offerManager.makeOfferEth{value: 0.1 ether}(0);
        vm.stopPrank();

        // we minted tokenId(1) to address(this) in the beginning of this function
        bluxeToken.approve(address(Bluxe), 1);
        Bluxe.createListing(address(bluxeToken), 1, listingPrice, false, 0);

        // we cannot make offer on our own listing
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        vm.prank(address(this));
        offerManager.makeOfferEth{value: 0.2 ether}(1);

        // now let's make Offer
        vm.prank(fakeUser);
        offerManager.makeOfferEth{value: 0.2 ether}(1);

        // Top Offerer Cannot Be Reduced their offer
        vm.expectRevert();
        offerManager.makeOfferEth{value: 0.1 ether}(1);

        // now pendingWithdrawals should be 0.5 ether (from buy above)
        assertEq(bluxeStorage.getPendingETH(fakeUser), 0.5 ether);
        // offer mapping should be updated now
        (uint256 offerAmount, ) = bluxeStorage.getOffer(1, fakeUser);
        assertEq(offerAmount, 0.2 ether);

        (address topOfferer, uint256 topOffererAmount, ) = bluxeStorage.getTopOffer(1);
        assertEq(topOffererAmount, 0.2 ether);
        // offers should be true now in mapping
        assertEq(bluxeStorage.getIsOfferer(1, fakeUser), true);
        vm.stopPrank();
    }

    // -----------------Cancel Offer----------------- //
    function testCancelOffer() public {
        bluxeToken.mint("", "", "", address(this));
        bluxeToken.approve(address(Bluxe), 1);
        // let's create an offer now
        Bluxe.createListing(address(bluxeToken), 1, listingPrice, false, 0);

        // let's try to cancel non-existing offer
        vm.startPrank(fakeUser);
        // we dont maked any offer on tokenId(0)
        vm.expectRevert();
        offerManager.cancelOffer(0);

        // it should be revert() => reason(we are not sending enough eth)
        vm.expectRevert();
        offerManager.makeOfferEth(1);

        vm.deal(fakeUser, 1 ether);
        offerManager.makeOfferEth{value: 0.1 ether}(1);

        // Cancel existing offer
        offerManager.cancelOffer(1);

        // offer mapping should be updated now
        (uint256 offerAmount, ) = bluxeStorage.getOffer(1, fakeUser);
        assertEq(offerAmount, 0);

        // pendingWithdrawals should be updated now with 0.1 ether (refunded amount)
        assertEq(bluxeStorage.getPendingETH(fakeUser), 0.1 ether);

        // offers should be false now in mapping because we cancelled the offer
        assertEq(bluxeStorage.getIsOfferer(1, fakeUser), false);

        // top offer amount should be 0 now if this was the top offer
        (address topOfferer, uint256 topOffererAmount, ) = bluxeStorage.getTopOffer(1);
        assertEq(topOffererAmount, 0);
        // top offerer should be address(0) now
        assertEq(topOfferer, address(0));
        vm.stopPrank();
    }

    //
    function testTrackHighestOffer() public {
        bluxeToken.mint("", "", "", address(this));
        bluxeToken.approve(address(Bluxe), 1);
        // let's create an offer now
        Bluxe.createListing(address(bluxeToken), 1, listingPrice, false, 0);
        vm.prank(fakeUser);
        vm.deal(fakeUser, 1 ether);
        offerManager.makeOfferEth{value: 0.2 ether}(1);
        address secondFakeUser = address(0xd4cde);
        vm.deal(secondFakeUser, 1 ether);
        vm.prank(secondFakeUser);
        offerManager.makeOfferEth{value: 0.6 ether}(1);
        (address topOfferer, uint256 topOfferAmount, ) = offerManager.trackHighestOffer(1);
        assert(topOfferer == secondFakeUser);
        assertEq(topOfferAmount, 0.6 ether);
    }

    // -------------- Seller accept an offer(accept highest offer or specific buyer) -----------------
    function testAcceptAnOfferFromSpecificBuyer() public {
        bluxeToken.mint("", "", "", address(this));
        bluxeToken.approve(address(Bluxe), 1);
        // let's create an offer now
        Bluxe.createListing(address(bluxeToken), 1, listingPrice, false, 0);
        vm.prank(fakeUser);
        vm.deal(fakeUser, 1 ether);
        offerManager.makeOfferEth{value: 0.2 ether}(1);
        address secondFakeUser = address(0xd4cde);
        vm.deal(secondFakeUser, 1 ether);
        vm.prank(secondFakeUser);
        offerManager.makeOfferEth{value: 0.6 ether}(1);

        // try to accept offer from non-seller
        vm.prank(secondFakeUser);
        vm.expectRevert();
        Bluxe.acceptOffer(fakeUser, 1);
        // now accept offer from fakeUser (specific buyer)

        // prank with address(Bluxe) because msg.sender should makeOffer() wants the sender to be the token owner,
        // and in this case, the token owner is address(this) which is the test contract,
        // cuz when we created listing above, the contract transferred the NFT from address(this) to marketplace for escrow.
        // during acceptOffer():
        // seller is NOT owner anymore
        // marketplace is owner
        // so approval check is pointless and should be removed

        Bluxe.acceptOffer(fakeUser, 1);
        // let's check How much amount in offers mapping for fakeUser after accepting offer
        (uint256 offerAmount, ) = bluxeStorage.getOffer(1, fakeUser);
        assertEq(offerAmount, 0 ether);
        // Listing should be inactive now
        assertEq(bluxeStorage.getListing(1).active, false);
        // Nft owner should be fakeUser after claim
        vm.prank(fakeUser);
        Bluxe.claimOfferNFT(1);
        assertEq(bluxeToken.ownerOf(1), fakeUser);
        // try to accept offer of already sold item
        //  we will create a new address to buy the item first
        address thirdFakeUser = address(0xaabbc);
        // this thirdFakeUser will buy the that secondFakeUser's offer
        // we minted tokenId(0) to address(this) in the beginning of this test contract
        // and we also created listing for tokenId(0) in setUp()
        // so let's buy tokenId(0) first
        vm.prank(thirdFakeUser);
        vm.deal(thirdFakeUser, 1 ether);
        Bluxe.buyItemWithEth{value: 0.5 ether}(0);
        // it should be revert() => reason(Item not active)
        vm.expectRevert();
        Bluxe.acceptOffer(fakeUser, 0);

        (uint96 platformFeeBps, address platformFeeRecipient) = bluxeStorage.getPlatformDetails();
        console.log("platformFeeRecipient: ");
        console.log(platformFeeRecipient);
        console.log("msg.sender");
        console.log(msg.sender);

        // check Royalty...
        (address r1, uint a1) = bluxeToken.royaltyInfo(1, 0.2 ether);
        assert(r1 == msg.sender);
        assert(a1 == 0.01 ether);

        // Calculate marketplace fee...
        uint marketplaceFee = /* Sale Price */ (0.2 ether * /* Platform Fee */ 350) / 10000;
        assert(marketplaceFee == 0.007 ether);
        // Verify balance in pendingWithdraw
        // @Note Marketplace Owner & Royalty Receiver -> msg.sender
        assertEq(
            bluxeStorage.getPendingETH(msg.sender),
            0.007 ether + 0.01 ether + 0.025 ether + 0.0175 ether
        );
        // @dev address(this) -> Seller
        assertEq(bluxeStorage.getPendingETH(address(this)), 0.4575 ether + 0.183 ether);
    }

    // --------- Seller can accept highest without specifying buyer ---------

    function testAcceptHighestOffer() public {
        // first make an offer => 1st Offer
        vm.prank(fakeUser);
        vm.deal(fakeUser, 0.3 ether);
        offerManager.makeOfferEth{value: 0.1 ether}(0);

        // first make an offer => 2nd Offer
        address secondFakeUser = address(0xce);
        vm.prank(secondFakeUser);
        vm.deal(secondFakeUser, 0.3 ether);
        offerManager.makeOfferEth{value: 0.3 ether}(0);

        // track and acccept highest offer
        (address tOf, uint aOf, ) = offerManager.trackHighestOffer(0);
        // NOTE:
        // We made _acceptOffer internal because a nonReentrant function cannot call
        // another nonReentrant external/public function. Internal functions bypass
        // the reentrancy guard and allow acceptHighestOffer() to reuse the logic safely.
        //
        // For testing purposes, nonReentrant was temporarily removed and will be
        // re-enabled after all tests are completed.

        // Bluxe.acceptHighestOffer(address(bluxeToken), 0);
        // assert(tOf == secondFakeUser);
        // assert(aOf == 0.3 ether);
        // assertEq(bluxeStorage.getPendingETH(address(this)) , 0.2745 ether);
        // assertEq(bluxeStorage.getPendingETH(msg.sender) , 0.0255 ether );
    }

    // ----------- Withdraw -----------
    function testWithdraw() public {
        vm.prank(fakeUser);
        vm.deal(fakeUser, 0.6 ether);
        Bluxe.buyItemWithEth{value: 0.5 ether}(0);

        // try to run withdraw function with zero amount
        vm.expectRevert();
        vm.prank(address(this));
        Bluxe.withdrawEth(0 ether);

        // it will revert becauce fakeUser don't have eth
        vm.prank(fakeUser);
        vm.expectRevert();
        Bluxe.withdrawEth(0.01 ether);
        // after buyItemWithEth(), seller have now 0.4575 eth
        vm.prank(address(this));

        // expect the event
        vm.expectEmit(true, true, true, true);
        emit WithdrawnETH(address(this), 0.01 ether);
        Bluxe.withdrawEth(0.01 ether);

        // after successfully withdraw , balance of seller is now 0.4475 eth
        assert(bluxeStorage.getPendingETH(address(this)) == 0.4475 ether);
    }

    function testWithdrawAll() public {
        // try to run withdraw function with zero amount
        vm.expectRevert();
        vm.prank(address(this));
        Bluxe.withdrawAllEth();

        // it will revert becauce fakeUser don't have eth
        vm.prank(fakeUser);
        vm.expectRevert();
        Bluxe.withdrawAllEth();

        vm.prank(fakeUser);
        vm.deal(fakeUser, 0.6 ether);
        Bluxe.buyItemWithEth{value: 0.5 ether}(0);
        Bluxe.withdrawAllEth();

        assert(bluxeStorage.getPendingETH(address(this)) == 0 ether);
    }

    function testUpdatePlatformFee() public {
        address owner = bluxeStorage.owner();
        console.log("Owner: ");
        console.log(owner);
        // let's set new royalty receiver with zero address
        vm.startPrank(owner);
        vm.expectRevert();
        Bluxe.updatePlatformFee(300, address(0));
        // let's set new platform fee receiver with platform fee > 1000
        vm.expectRevert();
        Bluxe.updatePlatformFee(1500, msg.sender);
        vm.stopPrank();

        // try to set fees and receipient without Owner
        vm.expectRevert();
        vm.prank(fakeUser);
        Bluxe.updatePlatformFee(900, msg.sender);

        // expect the event
        vm.expectEmit(true, true, true, true);
        emit PlatformFeeUpdated(450, fakeUser);
        // now set new fees and receipient

        vm.prank(owner);
        Bluxe.updatePlatformFee(450, fakeUser);
        assert(bluxeStorage.platformFeeRecipient() == fakeUser);
        assertEq(bluxeStorage.platformFeeBps(), 450);
    }

    // -- Get Listing details ----
    function testGetListing() public {
        assert(bluxeStorage.getListing(0).price == 0.5 ether);
        assert(bluxeStorage.getListing(0).seller == address(this));
        assert(bluxeStorage.getListing(0).nftContract == address(bluxeToken));
        assert(bluxeStorage.getListing(0).active == true);
        assert(bluxeStorage.getListing(0).tokenId == 0);

        // let's buy item
        vm.prank(fakeUser);
        vm.deal(fakeUser, 0.6 ether);
        Bluxe.buyItemWithEth{value: 0.5 ether}(0);
        // check detail agains when item was sold out
        assert(bluxeStorage.getListing(0).active == false);
    }

    // next Listing Id
    function testNextListingId() public {
        assertEq(Bluxe.nextListingId(), 1);
    }
    // ------------------- BluxeToken.sol ------------------- //
    // ---------------- Mint Functions ---------------- //
    function testMint() public {
        // it will revert() => reason(we passes zero address as receiver)
        vm.expectRevert();
        bluxeToken.mint("", "", "", address(0));
        // mint an check next Token ID
        // next Token ID should be 1
        assertEq(bluxeToken.getNextTokenID(), 1);
        bluxeToken.mint("eagle", "pic.eagle", "eagle nest ii", address(this));
        assertEq(bluxeToken.getNextTokenID(), 2);
        // verify owner of tokenId(1)
        assertEq(bluxeToken.ownerOf(1), address(this));
        // let's change maximum supply and mint
        vm.prank(msg.sender);
        bluxeToken.setMaxSupply(2);
        // it will revert() => reason(maximum supply reached)
        vm.expectRevert();
        bluxeToken.mint("", "", "", address(this));

        // Buy Token and verify Royalty Info
        vm.prank(fakeUser);
        vm.deal(fakeUser, 1 ether);
        Bluxe.buyItemWithEth{value: 0.5 ether}(0);
        // let's verify royalty info
        (address r1, uint256 a1) = bluxeToken.royaltyInfo(0, 0.5 ether);
        assertEq(r1, msg.sender);
        assertEq(a1, 0.025 ether);
        // verify nftData mapping
        // make nftData public for testing
        // for now i'll comment this test because nftData is private
        // (string memory name, string memory imageURI, string memory metadataURI) = bluxeToken.nftData(1);
        // assertEq(name , "eagle");
        // assertEq(imageURI , "pic.eagle");
        // assertEq(metadataURI , "eagle nest ii");
    }
    // ---------------- Burn Functions ---------------- //
    function testBurnFunction() public {
        // mint a token first
        bluxeToken.mint("", "", "", address(this));
        // try to burn without approval
        vm.expectRevert();
        bluxeToken.burn(1);
        // now approve and burn
        bluxeToken.approveBurn(address(this), 1);
        bluxeToken.burn(1);
        // verify ownerOf(1) should be revert now
        vm.expectRevert();
        bluxeToken.ownerOf(1);

        // mint again and and set approval then revoke approval and try to burn
        bluxeToken.mint("", "", "", address(this));
        bluxeToken.approveBurn(address(this), 2);
        // revoke approval
        // try to run revokeBurnApproval without owner
        vm.prank(fakeUser);
        vm.expectRevert();
        bluxeToken.revokeBurnApproval(address(this), 2);
        // now revoke with owner
        bluxeToken.revokeBurnApproval(address(this), 2);
        vm.expectRevert();
        bluxeToken.burn(2);
        // now approve again and burn
        bluxeToken.approveBurn(address(this), 2);
        bluxeToken.burn(2);
    }

    // ---------------- tokenURI ---------------- //
    function testTokenURI() public {
        // mint a token first
        bluxeToken.mint("Lion", "pic.lion", "lion king", address(this));
        string memory uri = bluxeToken.tokenURI(1);
        // verify that tokenURI contains expected substrings
        assert(bytes(uri).length > 0);
        assert(bytes(uri).length > bytes("data:application/json;base64,").length);
    }
    // ---------------- Set Max Supply ---------------- //
    function testSetMaxSupply() public {
        // try to set max supply without owner
        vm.prank(fakeUser);
        vm.expectRevert();
        bluxeToken.setMaxSupply(200);
        // try to set max supply more than 10000
        vm.prank(msg.sender);
        vm.expectRevert();
        bluxeToken.setMaxSupply(15000);

        // now set with owner
        vm.prank(msg.sender);
        bluxeToken.setMaxSupply(200);
        // verify max supply
        assertEq(bluxeToken.maximumSupply(), 200);
    }
    // ---------------- Support Interface ---------------- //
    function testSupportInterface() public {
        // ERC721 interface id = 0x80ac58cd
        assert(bluxeToken.supportsInterface(0x80ac58cd) == true);
        // ERC2981 interface id = 0x2a55205a
        assert(bluxeToken.supportsInterface(0x2a55205a) == true);
        // ERC165 interface id = 0x01ffc9a7
        assert(bluxeToken.supportsInterface(0x01ffc9a7) == true);
        // random interface id = 0xffffffff
        assert(bluxeToken.supportsInterface(0xffffffff) == false);
    }
    // ---------------- Create Hash Voucher ---------------- //
    struct LazyVoucher {
        string n;
        string i;
        string d;
        address t;
        uint256 p;
        uint256 nonce;
    }
    function testHashVoucher() public {
        // mint a token first
        bluxeToken.mint("Tiger", "pic.tiger", "tiger king", address(this));
        BluxeToken.LazyVoucher memory v = BluxeToken.LazyVoucher({
            n: "Tiger",
            i: "pic.tiger",
            d: "tiger king",
            p: 0.5 ether,
            c: msg.sender,
            nonce: 0
        });

        bytes32 Type = keccak256(
            "LazyVoucher(string n, string i, string d, address t, uint256 p, uint256 nonce)"
        );
        bytes32 actualHash = bluxeToken._hashVoucher(v);
        assert(actualHash != bytes32(0));
    }
    // Fallback functions to receive ether
    receive() external payable {}
    fallback() external payable {}
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

import "./Sweepable.sol";
import "./access/AccessControl.sol";
import "./assets/erc721/Test721.sol";
import "./assets/erc1155/Test1155.sol";
import "./interfaces/IAssets.sol";

/** @title NFT marketplace creation contract.
 * @author https://github.com/abhishekthak344
 */
contract Marketplace is AccessControl, Pausable, Sweepable, ERC1155Holder, IERC721Receiver {
  using SafeERC20 for IERC20;
  using Counters for Counters.Counter;

  /** Role identifier for the NFT creator role. */
  bytes32 public constant CREATOR_ROLE = keccak256("CREATOR_ROLE");

  /** Auction duration timestamp. */
  uint256 public biddingTime;

  /** Minimum auction duration timestamp. */
  uint256 public minBiddingTime;

  /** Maximum auction duration timestamp. */
  uint256 public maxBiddingTime;

  /** Counts total number of orders. */
  Counters.Counter private _numOrders;

  /** Address of the token used to pay for items. */
  address public acceptedToken;

  /** Address of the Test 721 contract. */
  address public test721;

  /** Address of the Test 1155 contract. */
  address public test1155;

  /** Emitted when a new order is placed. */
  event PlacedOrder(uint256 indexed orderId, address itemContract, uint256 indexed itemId, address indexed owner, uint256 basePrice);

  /** Emitted when an order is cancelled. */
  event CancelledOrder(uint256 indexed orderId, bool isSold);

  /** Emitted at the new highest bid. */
  event NewHighestBid(uint256 indexed orderId, address indexed maker, uint256 bidAmount);

  /** Emitted when the bidding time changes. */
  event BiddingTimeChanged(address from, uint256 newBiddingTime);

  /** Emitted when the auction is finished. */
  event AuctionFinished(uint256 indexed orderId, uint256 numBids);

  /** Emitted when a new purchase occures. */
  event Purchase(uint256 indexed orderId, address itemContract, uint256 indexed itemId, address maker, address taker, uint256 price);

  /**
   * @dev Checks if the given number is greater than zero.
   */
  modifier notZero(uint256 num) {
    require(num > 0, "Price & bid step can't be zero");
    _;
  }

  /** Order type: fixed price or auction. */
  enum OrderType {
    FixedPrice,
    Auction
  }

  /** Order struct. */
  struct Order {
    /** Item contract address. */
    address itemContract;
    /** Item id. */
    uint256 itemId;
    /** Base price in ACDM tokens. */
    uint256 basePrice;
    /** Listing timestamp. */
    uint256 listedAt;
    /** Expiration timestamp - 0 for fixed price. */
    uint256 expiresAt;
    /** Ending time - set at cancellation. */
    uint256 endTime;
    /** Number of bids, always points to last (i.e. highest) bid. */
    uint256 numBids;
    /** Bid step in ACDM tokens. */
    uint256 bidStep;
    /** Maker address. */
    address maker;
    /** Order type. */
    OrderType orderType;
  }

  /** Bid struct. */
  struct Bid {
    /** Bid amount in ACDM tokens. */
    uint256 amount;
    /** Bidder address. */
    address bidder;
  }

  /** Orders by id. */
  mapping(uint256 => Order) public orders; // orderId => Order

  /** Bids by order and bid id. */
  mapping(uint256 => mapping(uint256 => Bid)) public bids; // orderId => bidId => Bid

  /** @notice Creates marketplace contract.
   * @dev Grants `DEFAULT_ADMIN_ROLE` to `msg.sender`.
   * Grants `CREATOR_ROLE` to `_itemCreator`.
   * @param _biddingTime Initial bidding time.
   * @param _acceptedToken The address of the token used for payments.
   * @param _itemCreator The address of the item creator.
   * @param _nftName Name of the EssentialImages contract.
   * @param _nftSymbol Symbol of the EssentialImages contract.
   * @param _uri URI for 1155 token types.
   */
  constructor(
    uint256 _biddingTime,
    uint256 _minBiddingTime,
    uint256 _maxBiddingTime,
    address _acceptedToken,
    address _itemCreator,
    string memory _nftName,
    string memory _nftSymbol,
    string memory _uri
  ) {
    biddingTime = _biddingTime;
    minBiddingTime = _minBiddingTime;
    maxBiddingTime = _maxBiddingTime;

    test721 = address(new Test721(_nftName, _nftSymbol));
    acceptedToken = _acceptedToken;
    test1155 = address(new Test1155(_uri));

    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(CREATOR_ROLE, _itemCreator);
  }

  /** @notice Pausing some functions of contract.
    @dev Available only to admin.
    Prevents calls to functions with `whenNotPaused` modifier.
  */
  function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _pause();
  }

  /** @notice Unpausing functions of contract.
    @dev Available only to admin.
  */
  function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
    _unpause();
  }

  /** @notice Mints new ERC721 item.
   * @dev Calls `EssentialItems.safeMint` function.
   *  Available only to users with `CREATOR_ROLE`.
   *
   * @param to The address to mint to.
   * @param tokenURI URI of the new item.
   */
  function createItem(address to, string memory tokenURI)
    external
    onlyRole(CREATOR_ROLE)
    whenNotPaused
    returns (uint256 itemId)
  {
    itemId = IAssets(acdm721).safeMint(to, tokenURI);
  }

  /** @notice Mint a batch of tokens into existence and send them to the `to` address.
   * @param to The address to receive all NFTs within the newly-minted group.
   * @param ids The item IDs for the new items to create.
   * @param amounts The amount of each corresponding item ID to create.
   */
  function createItemsBatch(
    address to,
    uint256[] memory ids,
    uint256[] memory amounts
  )
    external
    onlyRole(CREATOR_ROLE)
    whenNotPaused
  {
    IAssets(test1155).mintBatch(to, ids, amounts, "");
  }

  /** @notice Changes bidding time.
   * @dev Available only to admin.
   *
   * Emits a {BiddingTimeChanged} event.
   *
   * @param _biddingTime New bidding time (timestamp).
   */
  function changeBiddingTime(uint256 _biddingTime)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
  {
    require(_biddingTime > minBiddingTime && _biddingTime < maxBiddingTime, "Time must be within the min and max");
    biddingTime = _biddingTime;
    emit BiddingTimeChanged(msg.sender, _biddingTime);
  }

  /** @notice Lists user item with a fixed price on the marketplace.
   *
   * Requirements:
   * - `basePrice` can't be zero.
   *
   * @param itemId Item ID.
   * @param basePrice Price of the item.
   */
  function listFixedPrice(address itemContract, uint256 itemId, uint256 basePrice)
    external
    whenNotPaused
    notZero(basePrice)
  {
    _addOrder(itemContract, itemId, basePrice, 0, OrderType.FixedPrice);
  }

  /** @notice Lists user auction item on the marketplace.
   *
   * Requirements:
   * - `basePrice` can't be zero.
   * - `bidStep` can't be zero.
   *
   * @param itemId Item ID.
   * @param basePrice Price of the item.
   * @param bidStep Bid step.
   */
  function listAuction(address itemContract, uint256 itemId, uint256 basePrice, uint256 bidStep)
    external
    whenNotPaused
    notZero(basePrice)
    notZero(bidStep)
  {
    _addOrder(itemContract, itemId, basePrice, bidStep, OrderType.Auction);
  }

  /** @notice Allows user to buy an item from an order with a fixed price.
   * @param orderId Order ID.
   */
  function buyOrder(uint256 orderId)
    external
    whenNotPaused
  {
    Order memory order = orders[orderId];
    require(order.basePrice > 0 && order.endTime == 0, "Order cancelled or not exist");
    require(order.orderType == OrderType.FixedPrice, "Can't buy auction order");
    require(msg.sender != order.maker, "Can't buy from yourself");

    // Transfer NFT to `msg.sender` and ACDM to order maker
    _exchange(orderId, order.itemContract, order.itemId, order.basePrice, msg.sender, order.maker, msg.sender);

    _cancelOrder(orderId, true);
  }

  /** @notice Allows user to bid on an auction.
   *
   * Requirements:
   * - `bidAmount` must be higher than the last bid + bid step.
   *
   * @param orderId Order ID.
   * @param bidAmount Amount in ACDM tokens.
   */
  function makeBid(uint256 orderId, uint256 bidAmount) external whenNotPaused {
    Order storage order = orders[orderId];
    require(order.expiresAt > block.timestamp, "Bidding time is over");
    require(msg.sender != order.maker, "Can't bid on your own order");

    uint256 numBids = order.numBids;
    Bid storage lastBid = bids[orderId][numBids];
    require(
      bidAmount > (order.basePrice + order.bidStep) && bidAmount > (lastBid.amount + order.bidStep),
      "Bid must be more than highest + bid step"
    );

    // Transfer ACDM tokens
    _transferTokens(msg.sender, address(this), lastBid.bidder == msg.sender ? (bidAmount - lastBid.amount) : bidAmount);

    // Return ACDM to the last bidder
    if (numBids > 0 && lastBid.bidder != msg.sender) _transferTokens(address(0), lastBid.bidder, lastBid.amount);

    order.numBids++;
    bids[orderId][order.numBids] = Bid({
      amount: bidAmount,
      bidder: msg.sender
    });

    emit NewHighestBid(orderId, msg.sender, bidAmount);
  }

  /** @notice Allows user to cancel an order with a fixed price.
   *
   * Requirements:
   * - `msg.sender` must be the creator of the order.
   *
   * @param orderId Order ID.
   */
  function cancelOrder(uint256 orderId) external whenNotPaused {
    Order memory order = orders[orderId];
    require(msg.sender == order.maker, "Not the order creator");
    require(order.orderType == OrderType.FixedPrice, "Can't cancel an auction order");

    _cancelOrder(orderId, false);
  }

  /** @notice Allows user to finish the auction.
   *
   * Requirements:
   * - `msg.sender` must be the creator of the order.
   * - `order.expiresAt` must be greater than the current timestamp (`block.timestamp`).
   *
   * @param orderId Order ID.
   */
  function finishAuction(uint256 orderId) external whenNotPaused {
    Order storage order = orders[orderId];
    require(order.endTime == 0, "No such order");
    require(msg.sender == order.maker, "Not the order creator");
    require(order.orderType == OrderType.Auction, "Not an auction order");
    require(order.expiresAt <= block.timestamp, "Can't finish before bidding time");

    uint256 numBids = order.numBids;
    Bid storage lastBid = bids[orderId][numBids];
    if (numBids > 2) {
      _exchange(orderId, order.itemContract, order.itemId, lastBid.amount, address(0), order.maker, lastBid.bidder);
      _cancelOrder(orderId, true);
    } else {
      // Return ACDM to the last bidder
      if (numBids > 0) _transferTokens(address(0), lastBid.bidder, lastBid.amount);
      _cancelOrder(orderId, false);
    }

    emit AuctionFinished(orderId, numBids);
  }

  /** @notice Adds new order to the marketplace.
   *
   * Emits a {PlacedOrder} event.
   *
   * @param itemContract Item contract address.
   * @param itemId Item ID.
   * @param basePrice Price of the item.
   * @param bidStep Bid step.
   * @param orderType Order type (see `OrderType` enum).
   */
  function _addOrder(address itemContract, uint256 itemId, uint256 basePrice, uint256 bidStep, OrderType orderType) private {
    _numOrders.increment();
    uint256 numOrders = _numOrders.current();

    Order storage order = orders[numOrders];
    order.itemContract = itemContract;
    order.itemId = itemId;
    order.basePrice = basePrice;
    order.listedAt = block.timestamp;
    order.maker = msg.sender;
    order.orderType = orderType;
    if (orderType == OrderType.Auction) {
      order.expiresAt = block.timestamp + biddingTime;
      order.bidStep = bidStep;
    }

    _transferItem(msg.sender, address(this), itemContract, itemId);

    emit PlacedOrder(numOrders, itemContract, itemId, msg.sender, basePrice);
  }

  /** @notice Exchanges ACDM tokens and Items between users.
   * @dev `payer` here is either `itemRecipient` or `address(0)`
   * which means that we should transfer ACDM from the contract.
   *
   * @param orderId Order ID.
   * @param itemContract Item contract address.
   * @param itemId Item ID.
   * @param price Item price in ACDM tokens.
   * @param payer Address of the payer.
   * @param itemOwner Address of the item owner.
   * @param itemRecipient Address of the item recipient.
   */
  function _exchange(
    uint256 orderId,
    address itemContract,
    uint256 itemId,
    uint256 price,
    address payer,
    address itemOwner,
    address itemRecipient
  ) private {
    _transferTokens(payer, itemOwner, price);

    _transferItem(address(this), itemRecipient, itemContract, itemId);

    emit Purchase(orderId, itemContract, itemId, itemOwner, itemRecipient, price);
  }

  /** @notice Transfers Item to specified address.
   * @param from The address to transfer from.
   * @param to The address to transfer to.
   * @param itemContract Item contract address.
   * @param itemId Item ID.
   */
  function _transferItem(address from, address to, address itemContract, uint256 itemId) private {
    itemContract == acdm1155 ? IAssets(itemContract).safeTransferFrom(from, to, itemId, 1, "")
    : IAssets(itemContract).safeTransferFrom(from, to, itemId);
  }

  /** @notice Transfers ACDM tokens between users.
   * @param from The address to transfer from.
   * @param to The address to transfer to.
   * @param amount Transfer amount in ACDM tokens.
   */
  function _transferTokens(address from, address to, uint256 amount) private {
    from != address(0) ? IERC20(acceptedToken).safeTransferFrom(from, to, amount)
    : IERC20(acceptedToken).safeTransfer(to, amount);
  }

  /** @notice Cancelling order by id.
   * @param orderId Order ID.
   * @param isSold Indicates wheter order was purchased or simply cancelled by the owner.
   */
  function _cancelOrder(uint256 orderId, bool isSold) private {
    Order storage order = orders[orderId];
    order.endTime = block.timestamp;

    // Return item if it's not sold
    if (!isSold) _transferItem(address(this), order.maker, order.itemContract, order.itemId);

    emit CancelledOrder(orderId, isSold);
  }

  /** @notice Checks if item is currently listed on the marketplace.
   * @param itemContract Item contract address.
   * @param itemId Item ID.
   * @return boob Whether the item in an open order.
   */
  function isListed(address itemContract, uint256 itemId) external view returns(bool) {
    uint256 numOrders = _numOrders.current();
    for (uint256 i = 1; i <= numOrders; i++) {
      if (
        orders[i].endTime == 0
        && orders[i].itemId == itemId
        && orders[i].itemContract == itemContract
      ) return true;
    }
    return false;
  }

  /** @notice Returns the entire order history on the market.
   * @return Array of `Order` structs.
   */
  function getOrdersHistory() external view returns(Order[] memory) {
    uint256 numOrders = _numOrders.current();
    Order[] memory ordersArr = new Order[](numOrders);
   
    for (uint256 i = 1; i <= numOrders; i++) {
      ordersArr[i - 1] = orders[i];
    }
    return ordersArr;
  }

  /** @notice Returns current open orders on the market.
   * @return Array of `Order` structs.
   */
  function getOpenOrders() external view returns(Order[] memory) {
    Order[] memory openOrders = new Order[](countOpenOrders());

    uint256 counter;
    uint256 numOrders = _numOrders.current();
    for (uint256 i = 1; i <= numOrders; i++) {
      if (orders[i].endTime == 0) {
        openOrders[counter] = orders[i];
        counter++;
      }
    }
    return openOrders;
  }

  /** @notice Counts currently open orders.
   * @return numOpenOrders Number of open orders.
   */
  function countOpenOrders() public view returns(uint256 numOpenOrders) {
    uint256 numOrders = _numOrders.current();
    for (uint256 i = 1; i <= numOrders; i++) {
      if (orders[i].endTime == 0) {
        numOpenOrders++;
      }
    }
  }

  /** @notice Returns all marketplace bids sorted by orders.
   * @return Array of arrays (`Bid` structs array by each order).
   */
  function getBidsHistory() external view returns (Bid[][] memory) {
    uint256 numOrders = _numOrders.current();
    Bid[][] memory bidsHistory = new Bid[][](numOrders);

    for (uint256 i = 1; i <= numOrders; i++) {
      bidsHistory[i - 1] = getBidsByOrder(i);
    }

    return bidsHistory;
  }

  /** @notice Returns all bids by order id.
   * @param orderId Order ID.
   * @return Array of `Bid` structs.
   */
  function getBidsByOrder(uint256 orderId) public view returns (Bid[] memory) {
    uint256 numBids = orders[orderId].numBids;
    Bid[] memory orderBids = new Bid[](numBids);

    for (uint256 i = 1; i <= numBids; i++) {
      orderBids[i - 1] = bids[orderId][i];
    }

    return orderBids;
  }

  /** Always returns `IERC721Receiver.onERC721Received.selector`. */
  function onERC721Received(address, address, uint256, bytes memory) public virtual override returns (bytes4) {
    return this.onERC721Received.selector;
  }
}

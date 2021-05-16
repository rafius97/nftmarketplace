// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.7/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IERC1155.sol";
import "./interfaces/IWETH.sol";
import "hardhat/console.sol";

/**
 * @title A NFT Marketplace Contract
 * @author Rafael Romero
 */
contract NFTMarketplaceV1 is
    Initializable,
    ContextUpgradeable,
    OwnableUpgradeable
{
    using SafeMath for uint256;

    /**
     * @dev Returns the fee value that is taken from each transaction.
     */
    uint256 public fee;

    /**
     * @dev Returns the address who is holding the fees.
     */
    address payable public feeRecipient;

    // mapping of approved tokens for payment
    mapping(address => bool) private _whitelistedERC20;

    // instance of wrapped eth
    IWETH internal constant weth =
        IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    enum OfferStatus {ONGOING, CANCELLED}

    struct Offer {
        address seller;
        address token;
        uint256 tokenId;
        uint256 amount;
        uint256 deadline;
        uint256 priceUSD;
        OfferStatus status;
    }

    /**
     * @dev Returns the offer of a seller given a tokenId.
     */
    mapping(address => mapping(uint256 => Offer)) public offers;

    /**
     * @dev Emitted when `seller` creates a new offer of a ERC-1155 `token`
     * and its `tokenId`.
     */
    event OfferCreated(
        address indexed seller,
        address indexed token,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 deadline,
        uint256 priceUSD
    );

    /**
     * @dev Emitted when `buyer` accepts the offer of `seller`.
     */
    event OfferAccepted(
        address indexed buyer,
        address indexed seller,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 priceUSD
    );

    /**
     * @dev Emitted when `seller` cancels his offer.
     */
    event OfferCancelled(
        address indexed seller,
        address indexed token,
        uint256 indexed tokenId
    );

    /**
     * @dev Initializes the values for {feeRecipient} and {fee}.
     *
     * It is used to make the contract upgradeable.
     *
     * Requirements:
     *
     * - `_feeRecipient` cannot be the zero address.
     * - `_fee` must be greater than zero.
     */
    function initialize(
        address payable _feeRecipient,
        uint256 _fee
    ) external initializer {
        require(_feeRecipient != address(0));
        require(_fee > 0);
        __Context_init();
        __Ownable_init();
        feeRecipient = _feeRecipient;
        fee = _fee;
    }


    /**
     * @dev Creates an offer of an ERC-1155 Token.
     *
     * Emits a {OfferCreated} event.
     *
     * Requirements:
     *
     * - `_token` cannot be the zero address.
     * - `_tokenId` must be greater than zero.
     * - `_amount` must be greater than zero.
     * - `_deadline` must be greater than the current `block.timestamp`.
     * - `_priceUSD` must be greater than zero.
     */
    function createOffer(
        address _token,
        uint256 _tokenId,
        uint256 _amount,
        uint256 _deadline,
        uint256 _priceUSD
    ) external {
        require(_token != address(0), "NTFMarketplace: ZERO_ADDRESS");
        require(_tokenId > 0, "NTFMarketplace: ID_ERROR");
        require(_amount > 0, "NFTMarketplace: ZERO_AMOUNT");
        require(_deadline > block.timestamp, "NFTMarketplace: DEADLINE_ERROR");
        require(_priceUSD > 0, "NFTMarketplace: ZERO_PRICE_USD");

        offers[_msgSender()][_tokenId] = Offer(
            _msgSender(),
            _token,
            _tokenId,
            _amount,
            _deadline,
            _priceUSD,
            OfferStatus.ONGOING
        );
        emit OfferCreated(
            _msgSender(),
            _token,
            _tokenId,
            _amount,
            _deadline,
            _priceUSD
        );
    }

    /**
     * @dev Accepts an offer of an ERC-1155 Token using ERC-20 Tokens.
     *
     * Emits a {OfferAccepted} event.
     *
     * Requirements:
     *
     * - `_seller` cannot be the zero address.
     * - `_tokenId` must be greater than zero.
     * - `_amount` must be greater than zero.
     * - `_tokenPayment` cannot be the zero address and must be a 
     * valid ERC-20 Token address.
     */
    function acceptOfferWithTokens(
        address _seller, 
        uint256 _tokenId,
        uint256 _amount,
        address _tokenPayment
    ) external {
        require(_seller != address(0), "NTFMarketplace: ZERO_ADDRESS");
        require(_tokenId > 0, "NTFMarketplace: ID_ERROR");
        require(_amount > 0, "NFTMarketplace: ZERO_AMOUNT");
        require(_whitelistedERC20[_tokenPayment], "NFTMarketplace: TOKEN_NOT_ALLOWED");

        Offer memory offer = offers[_seller][_tokenId];
        require(
            offer.status != OfferStatus.CANCELLED,
            "NFTMarketplace: This offer is already cancelled"
        );

        // the price in USD has 8 decimals, so multiply by 10 ** 10 to get to 18 decimals
        uint256 tokenPrice = _getPriceByToken(_tokenPayment).mul(10**10);
        // add 18 twice to maintain precision in the next divide
        uint256 priceUSD = offer.priceUSD.mul(10**(18 + 18));
        uint256 finalAmount = priceUSD.div(tokenPrice);
        uint256 fees = finalAmount.div(fee);

        require(
            IERC20(_tokenPayment).allowance(_msgSender(), address(this)) >= finalAmount,
            "NTFMarketplace: INSUFFICIENT_ALLOWANCE"
        );

        // transfer tokens to the seller
        IERC20(_tokenPayment).transferFrom(
            _msgSender(), 
            _seller, 
            finalAmount.sub(fees)
        );
        
        require(
            IERC1155(offer.token).isApprovedForAll(_seller, address(this)),
            "NTFMarketplace: NOT_APPROVAL"
        );
        
        // transfer tokens to buyer
        IERC1155(offer.token).safeTransferFrom(
            _seller,
            _msgSender(),
            offer.tokenId,
            offer.amount,
            ""
        );

        IERC20(_tokenPayment).transferFrom(
            _msgSender(), 
            feeRecipient, 
            fees
        );

        // refund to sender
        uint256 remainderTokens = IERC20(_tokenPayment).allowance(_seller, address(this));
        IERC20(_tokenPayment).transferFrom(
            _msgSender(), 
            _msgSender(), 
            remainderTokens
        );

        emit OfferAccepted(
            _msgSender(),
            _seller,
            _tokenId,
            offer.amount,
            offer.priceUSD
        );

        // delete offer
        delete offers[offer.seller][_tokenId];
    }

    /**
     * @dev Accepts an offer of an ERC-1155 Token using ETH.
     *
     * Emits a {OfferAccepted} event.
     *
     * Requirements:
     *
     * - `_seller` cannot be the zero address.
     * - `_tokenId` must be greater than zero.
     */
    function acceptOfferWithETH(address _seller, uint256 _tokenId)
        external
        payable
    {
        require(_seller != address(0), "NTFMarketplace: ZERO_ADDRESS");
        require(_tokenId > 0, "NTFMarketplace: ID_ERROR");

        uint256 amount = msg.value;
        require(amount > 0, "NFTMarketplace: ZERO_AMOUNT");

        Offer memory offer = offers[_seller][_tokenId];
        require(
            offer.status != OfferStatus.CANCELLED,
            "NFTMarketplace: This offer is already cancelled"
        );

        // the price in USD has 8 decimals, so multiply by 10 ** 10 to get to 18 decimals
        uint256 tokenPrice = _getPriceByToken(address(weth)).mul(10**10);
        // add 18 twice to maintain precision in the next divide
        uint256 priceUSD = offer.priceUSD.mul(10**(18 + 18));

        uint256 finalAmount = priceUSD.div(tokenPrice);
        require(amount >= finalAmount, "NFTMarketplace: INSUFFICIENT_AMOUNT");

        uint256 fees = finalAmount.div(fee);

        // transfer eth to seller
        weth.deposit{value: amount}();
        weth.transfer(_seller, finalAmount.sub(fees));

        require(
            IERC1155(offer.token).isApprovedForAll(_seller, address(this)),
            "NTFMarketplace: NOT_APPROVAL"
        );
        // transfer tokens to buyer
        IERC1155(offer.token).safeTransferFrom(
            _seller,
            _msgSender(),
            offer.tokenId,
            offer.amount,
            ""
        );

        weth.transfer(feeRecipient, fees);
        // refund to sender
        weth.transfer(_msgSender(), weth.balanceOf(address(this)));

        emit OfferAccepted(
            _msgSender(),
            _seller,
            _tokenId,
            offer.amount,
            offer.priceUSD
        );
        // delete offer
        delete offers[offer.seller][_tokenId];
    }

    /**
     * @dev Cancels an offer of an ERC-1155 Token.
     *
     * Emits a {OfferCancelled} event.
     *
     * Requirements:
     *
     * - `_tokenId` must be greater than zero.
     */
    function cancelOffer(uint256 _tokenId) external {
        require(_tokenId > 0, "NFTMarketplace: ID_ERROR");

        Offer memory offer = offers[_msgSender()][_tokenId];
        require(
            offer.status != OfferStatus.CANCELLED,
            "NFTMarketplace: This offer is already cancelled"
        );

        offer.status = OfferStatus.CANCELLED;
        emit OfferCancelled(offer.seller, offer.token, offer.tokenId);
    }

    /**
     * @dev Sets the fees of each transaction.
     *
     * Requirements:
     *
     * - `_fee` must be greater than zero.
     * - Only the owner can change the value of {fee}.
     */
    function setFee(uint256 _fee) external onlyOwner {
        fee = _fee;
    }

    /**
     * @dev Sets the address who is hold the fees.
     *
     * Requirements:
     *
     * - `_feeRecipient` cannot be the zero address.
     * - Only the owner can change the address of the {feeRecipient}.
     */
    function setFeeRecipient(address payable _feeRecipient) external onlyOwner {
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Sets a whitelist of ERC-20 tokens for payment.
     *
     * Requirements:
     *
     * - `_paymentToken` cannot be the zero address.
     * - Only owner can change whether a token is accepted or not.
     */
    function setWhitelistedPaymentToken(
        address _paymentToken,
        bool isAccepted
    ) external onlyOwner {
        require(_paymentToken != address(0), "NFTMarketplace: ZERO_ADDRESS");
        _whitelistedERC20[_paymentToken] = isAccepted;
    }

    /**
     * @dev Returns the price of a token in USD.
     *
     * Requirements:
     *
     * - `_tokenPayment` cannot be the zero address and address must be
     * in the whitelist of ERC-20 Tokens.
     */
    function _getPriceByToken(address _tokenPayment)
        internal
        view
        returns (uint256)
    {
        require(
            _whitelistedERC20[_tokenPayment],
            "NFTMarketplace: TOKEN_NOT_ALLOWED"
        );

        AggregatorV3Interface priceETH =
            AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

        AggregatorV3Interface priceDAI =
            AggregatorV3Interface(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);

        AggregatorV3Interface priceLINK =
            AggregatorV3Interface(0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c);

        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        address link = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
        uint256 priceUSD;
        if (_tokenPayment == address(weth)) {
            (, int256 price, , , ) = priceETH.latestRoundData();
            priceUSD = uint256(price);
        } else if (_tokenPayment == dai) {
            (, int256 price, , , ) = priceDAI.latestRoundData();
            priceUSD = uint256(price);
        } else if (_tokenPayment == link) {
            (, int256 price, , , ) = priceLINK.latestRoundData();
            priceUSD = uint256(price);
        } else {
            revert();
        }
        return priceUSD;
    }

    function _checkOfferDeadlineBeforeAccept(Offer storage offer)
        internal
        returns (bool)
    {
        if (offer.deadline < block.timestamp) {
            offer.status = OfferStatus.CANCELLED;
            return false;
        }
        return true;
    }
}

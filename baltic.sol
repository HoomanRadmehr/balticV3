
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/IUniswapV3Pool.sol";
import "https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/ISwapRouter.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolImmutables.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolState.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolDerivedState.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolOwnerActions.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolActions.sol";
import "https://github.com/Uniswap/v3-core/blob/main/contracts/interfaces/pool/IUniswapV3PoolEvents.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";


contract Baltic is Ownable(msg.sender){
    using SafeMath for uint256;

    ERC20 public WMATIC;
    ERC20 public alternativeToken;
    IUniswapV3Pool public pool;
    ISwapRouter public router;
    ERC20 public WBTC;
    ERC20 public WETH;
    uint256 public tradingLeverage;
    uint256 public maticAmount;
    uint256 public alternativeTokenAmount;
    uint256 public maticAlternativeAmount;

    struct User {
        uint256 registrationTime;
        uint256 initialWbtcBalance;
        uint256 lastTradePrice;
        bool isFirstTime;
        bool isActive;
    }

    struct Trade {
        uint256 tradingPrice;
        uint256 wbtcBeforeTradeAmount;
        uint256 wbtcTradeAmount;
        string positionType;
        uint256 wethBeforeTradeAmount;
        uint256 wethTradeAmount;
        uint256 tradingTimestamp;
    }

    mapping(address => Trade[]) public trades;
    mapping(address => User) public users;
    mapping(address => bool) public IsApproved;
    address[] public registeredUsers;

    constructor(
        address _WBTC,
        address _WETH,
        address _MATIC,
        address _alternativeToken,
        address _pool,
        address _router,
        uint256 _tradingLeverage,
        uint256 _maticAmount,
        uint256 _alternativeTokenAmount,
        uint256 _maticAlternativeAmount
    ) {
        WBTC = ERC20(_WBTC);
        WETH = ERC20(_WETH);
        WMATIC = ERC20(_MATIC);
        alternativeToken = ERC20(_alternativeToken);
        pool = IUniswapV3Pool(_pool);
        router = ISwapRouter(_router);
        tradingLeverage = _tradingLeverage;
        maticAmount = _maticAmount;
        alternativeTokenAmount = _alternativeTokenAmount;
        maticAlternativeAmount = _maticAlternativeAmount;
    }

    function payReg() external{
        uint256 userMATICBalance = WMATIC.balanceOf(msg.sender);
        uint256 userAlternativeTokenBalance = alternativeToken.balanceOf(msg.sender);

        if (userMATICBalance >= maticAmount*(10**WMATIC.decimals()) && userAlternativeTokenBalance >= alternativeTokenAmount*(10**alternativeToken.decimals())) {
            require(WMATIC.transferFrom(msg.sender, owner(), maticAmount*(10**WMATIC.decimals())), "Failed to transfer MATIC from user to owner");
            require(alternativeToken.transferFrom(msg.sender, owner(), alternativeTokenAmount*(10**alternativeToken.decimals())), "Failed to transfer alternative token from user to owner");
        } 
        else if (userMATICBalance >= maticAlternativeAmount*(10**WMATIC.decimals())) {
            require(WMATIC.transferFrom(msg.sender, owner(), maticAlternativeAmount*(10**WMATIC.decimals())), "Failed to transfer alternative amount of MATIC from user to owner");
        } 
        else {
            revert("not enough token for registration");
        }
        
        User memory newUser;
        newUser.registrationTime = block.timestamp;
        newUser.initialWbtcBalance = 0;
        newUser.lastTradePrice = 0;
        newUser.isFirstTime = true;
        newUser.isActive = true;
        users[msg.sender] = newUser;
        registeredUsers.push(msg.sender);
    }

    function equalization(address user) internal {
        uint256 wbtcBalance = WBTC.balanceOf(user);
        uint256 wethBalance = WETH.balanceOf(user);
        uint256 lastPrice = fetchPrice();
        uint256 wbtcValueInWeth = wbtcBalance.mul(lastPrice);
        uint256 wethValueInWeth = wethBalance;

        if (wbtcValueInWeth > wethValueInWeth) {
            uint256 excessValue = (wbtcValueInWeth - wethValueInWeth) / 2;
            uint256 excessWbtc = excessValue.div(lastPrice);
            WBTC.transferFrom(user, address(this),excessWbtc);
            WBTC.approve(address(router),excessWbtc);
            executeSwap(WBTC, WETH, user, excessWbtc);
        } else if (wethValueInWeth > wbtcValueInWeth) {
            uint256 excessValue = (wethValueInWeth - wbtcValueInWeth) / 2;
            WETH.transferFrom(user,address(this),excessValue);
            WETH.approve(address(router),excessValue);
            executeSwap(WETH, WBTC, user, excessValue);
        }
    }

    function executeSwap(IERC20 token0, IERC20 token1, address user, uint256 amountIn) internal {

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(token0),
            tokenOut: address(token1),
            fee: 500,
            recipient: user,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        router.exactInputSingle(params);
    }

    function addTrade(address _userAddress,Trade memory _tradeInfo) internal {
        trades[_userAddress].push(_tradeInfo);
    }

    function balwap(address userAddress) external onlyOwner {
        if(users[userAddress].isFirstTime){
            uint256 currentPrice = fetchPrice();
            equalization(userAddress);
            users[userAddress].initialWbtcBalance = WBTC.balanceOf(userAddress);
            users[userAddress].lastTradePrice = currentPrice;
            users[userAddress].isFirstTime = false;
        }
        else{
            User memory thisUser = users[userAddress];
            uint256 currentPrice = fetchPrice();
            uint256 userLastPrice = thisUser.lastTradePrice;
            uint256 priceChange = userLastPrice > currentPrice ? userLastPrice - currentPrice : currentPrice - userLastPrice;
            uint256 timeElapsed = block.timestamp - thisUser.registrationTime;
            if (timeElapsed >= 3 * 30 days) {
                if (!reRegister(userAddress)) {
                    thisUser.isActive = false;
                    return ;
                }
            }

            if (currentPrice > userLastPrice) {
                uint256 tradeAmount = thisUser.initialWbtcBalance.mul(tradingLeverage).mul(priceChange).div(currentPrice);
                uint256 currentWBTCAmount = WBTC.balanceOf(userAddress);
                require(tradeAmount<currentWBTCAmount,"insufficient btc amount");
                WBTC.transferFrom(userAddress,address(this), tradeAmount);
                WBTC.approve(address(router),tradeAmount);
                uint256 currentWETHAmount = WETH.balanceOf(userAddress);
                executeSwap(WBTC, WETH, userAddress, tradeAmount);
                uint256 afterTradeWBTCAmount= WBTC.balanceOf(userAddress);
                uint256 afterTradeWETHAmount = WETH.balanceOf(userAddress);
                uint256 wbtcTradeAmount = currentWBTCAmount - afterTradeWBTCAmount;
                uint256 wethTradeAmount = afterTradeWETHAmount - currentWETHAmount;
                string memory tradingType = "SELL";
                Trade memory newTrade;
                newTrade.tradingPrice=currentPrice;
                newTrade.wbtcBeforeTradeAmount=currentWBTCAmount;
                newTrade.wethBeforeTradeAmount=currentWETHAmount;
                newTrade.wbtcTradeAmount=wbtcTradeAmount;
                newTrade.wethTradeAmount=wethTradeAmount;
                newTrade.positionType=tradingType;
                newTrade.tradingTimestamp=block.timestamp;
                addTrade(userAddress, newTrade);

            } else if (currentPrice < userLastPrice) {
                uint256 tradeAmount = thisUser.initialWbtcBalance.mul(tradingLeverage).mul(priceChange);
                uint256 currentWETHAmount = WETH.balanceOf(userAddress);
                require(tradeAmount<currentWETHAmount,"insufficient eth amount");
                WETH.transferFrom(userAddress, address(this),tradeAmount);
                WETH.approve(address(router),tradeAmount);
                uint256 currentWBTCAmount = WBTC.balanceOf(userAddress);
                executeSwap(WETH, WBTC, userAddress, tradeAmount);
                uint256 afterTradeWBTCAmount= WBTC.balanceOf(userAddress);
                uint256 afterTradeWETHAmount = WETH.balanceOf(userAddress);
                uint256 wbtcTradeAmount = afterTradeWBTCAmount -currentWBTCAmount;
                uint256 wethTradeAmount = currentWETHAmount - afterTradeWETHAmount;
                string memory tradingType = "BUY";
                Trade memory newTrade;
                newTrade.tradingPrice=currentPrice;
                newTrade.wbtcBeforeTradeAmount=currentWBTCAmount;
                newTrade.wethBeforeTradeAmount=currentWETHAmount;
                newTrade.wbtcTradeAmount=wbtcTradeAmount;
                newTrade.wethTradeAmount=wethTradeAmount;
                newTrade.positionType=tradingType;
                newTrade.tradingTimestamp=block.timestamp;
                addTrade(userAddress, newTrade);
            }
            users[userAddress].lastTradePrice = currentPrice;
        }
    }

    function reRegister(address user) internal returns (bool) {
        uint256 userMATICBalance = WMATIC.balanceOf(user);
        uint256 userAlternativeTokenBalance = alternativeToken.balanceOf(user);

        if (userMATICBalance >= maticAmount*(10**WMATIC.decimals()) && userAlternativeTokenBalance >= alternativeTokenAmount*(10**alternativeToken.decimals())) {
            require(WMATIC.transferFrom(user, owner(), maticAmount*(10**WMATIC.decimals())), "Failed to transfer MATIC from user to owner");
            require(alternativeToken.transferFrom(user, owner(), alternativeTokenAmount*(10**alternativeToken.decimals())), "Failed to transfer alternative token from user to owner");
        } 
        else if (userMATICBalance >= maticAlternativeAmount*(10**WMATIC.decimals())) {
            require(WMATIC.transferFrom(user, owner(), maticAlternativeAmount*(10**WMATIC.decimals())), "Failed to transfer alternative amount of MATIC from user to owner");
        } 
        else {
            users[user].isActive = false;
            return false;
        }
        
        users[user].registrationTime = block.timestamp;

        // equalization
        equalization(user);
        
        return true;
    }


    function fetchPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        uint256 price = (sqrtPriceX96/2**96)**2;
        return price;
    }

    function setMaticAmount(uint256 newAmount) public onlyOwner {
        maticAmount = newAmount;
    }

    function setAlternativeMaticAmount(uint256 newAmount) public onlyOwner {
        maticAlternativeAmount = newAmount;
    }

    function setAlternativeTokenAmount(uint256 newAmount) public onlyOwner {
        alternativeTokenAmount = newAmount;
    }

    function contractTermination() public {
        delete users[msg.sender];
        }
    }
    

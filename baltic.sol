// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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


interface IERC20WithDecimals is IERC20 {
    function decimals() external view returns (uint8);
}

contract Baltic is Ownable {
    using SafeMath for uint256;

    IERC20 public MATIC;
    IERC20 public alternativeToken;
    IUniswapV3Pool public pool;
    ISwapRouter public router;
    IERC20WithDecimals public WBTC;
    IERC20WithDecimals public WETH;
    uint256 public lastPrice;
    uint256 public tradingLeverage;
    uint256 public maticAmount;
    uint256 public alternativeTokenAmount;
    uint256 public maticAlternativeAmount;

    struct User {
        uint256 registrationTime;
        uint256 initialWbtcBalance;
        bool isActive;
    }
    mapping(address => User) public users;
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
        WBTC = IERC20WithDecimals(_WBTC);
        WETH = IERC20WithDecimals(_WETH);
        MATIC = IERC20(_MATIC);
        alternativeToken = IERC20(_alternativeToken);
        pool = IUniswapV3Pool(_pool);
        router = ISwapRouter(_router);
        tradingLeverage = _tradingLeverage;
        maticAmount = _maticAmount;
        alternativeTokenAmount = _alternativeTokenAmount;
        maticAlternativeAmount = _maticAlternativeAmount;
    }

    function payReg() external {
        require(!users[msg.sender].isActive, "Already registered");

        require(WBTC.approve(address(router), type(uint256).max), "Failed to approve WBTC to Uniswap");
        require(WETH.approve(address(router), type(uint256).max), "Failed to approve WETH to Uniswap");
        require(MATIC.approve(owner(), type(uint256).max), "Failed to approve MATIC to owner");
        require(alternativeToken.approve(owner(), type(uint256).max), "Failed to approve alternative token to owner");

        MATIC.transferFrom(msg.sender, owner(), maticAmount);
        alternativeToken.transferFrom(msg.sender, owner(), alternativeTokenAmount);
        
        equalization(msg.sender);

        User memory newUser;
        newUser.registrationTime = block.timestamp;
        newUser.initialWbtcBalance = WBTC.balanceOf(msg.sender);
        newUser.isActive = true;
        users[msg.sender] = newUser;
        registeredUsers.push(msg.sender);
    }

    function equalization(address user) internal {
        uint256 wbtcBalance = WBTC.balanceOf(user);
        uint256 wethBalance = WETH.balanceOf(user);

        uint256 wbtcValueInWeth = wbtcBalance.mul(lastPrice).div(10**WETH.decimals());
        uint256 wethValueInWeth = wethBalance;

        if (wbtcValueInWeth > wethValueInWeth) {
            uint256 excessValue = (wbtcValueInWeth - wethValueInWeth) / 2;
            uint256 excessWbtc = excessValue.mul(10**WBTC.decimals()).div(lastPrice);
            executeSwap(WBTC, WETH, user, excessWbtc);
        } else if (wethValueInWeth > wbtcValueInWeth) {
            uint256 excessValue = (wethValueInWeth - wbtcValueInWeth) / 2;
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

    function balwap() external onlyOwner {
        uint256 currentPrice = fetchPrice();
        uint256 priceChange = lastPrice > currentPrice ? lastPrice - currentPrice : currentPrice - lastPrice;
        uint256 priceChangeInWbtc = priceChange.div(lastPrice);

        for (uint256 i = 0; i < registeredUsers.length; i++) {
            User storage user = users[registeredUsers[i]];
            uint256 timeElapsed = block.timestamp - user.registrationTime;
            if (timeElapsed >= 3 * 30 days) {
                if (!reRegister(registeredUsers[i])) {
                    user.isActive = false;
                    continue;
                }
            }

            if (currentPrice > lastPrice) {
                uint256 tradeAmount = user.initialWbtcBalance.mul(tradingLeverage).mul(priceChangeInWbtc).div(10**WBTC.decimals());
                executeSwap(WBTC, WETH, registeredUsers[i], tradeAmount);
            } else if (currentPrice < lastPrice) {
                uint256 tradeAmount = user.initialWbtcBalance.mul(tradingLeverage).div(priceChangeInWbtc).div(10**WETH.decimals());
                executeSwap(WETH, WBTC, registeredUsers[i], tradeAmount);
            }
        }
        lastPrice = currentPrice;
    }

    function reRegister(address user) internal returns (bool) {
        uint256 userMATICBalance = MATIC.balanceOf(user);
        uint256 userAlternativeTokenBalance = alternativeToken.balanceOf(user);

        if (userMATICBalance >= maticAmount && userAlternativeTokenBalance >= alternativeTokenAmount) {
            require(MATIC.transferFrom(user, owner(), maticAmount), "Failed to transfer MATIC from user to owner");
            require(alternativeToken.transferFrom(user, owner(), alternativeTokenAmount), "Failed to transfer alternative token from user to owner");
        } 
        else if (userMATICBalance >= maticAlternativeAmount) {
            require(MATIC.transferFrom(user, owner(), maticAlternativeAmount), "Failed to transfer alternative amount of MATIC from user to owner");
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
}

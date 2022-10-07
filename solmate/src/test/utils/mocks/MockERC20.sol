// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {ERC20} from "../../../tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol, _decimals) {}

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    event UnsafeMinting(address indexed to, uint newBalance);

    function mintWithoutAdjustingTotalSupply(address to, uint value) public {
        // @audit Don't do this!
        //        Invalidates the invariant that the sum of all balances equals
        //        `totalSupply`.
        balanceOf[to] += value;

        emit UnsafeMinting(to, balanceOf[to]);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }
}

// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

import {ERC20} from "../tokens/ERC20.sol";

/**
 @audit Note the @dev comment?
 Before using any SafeTransferLib functions, always check that `token.code.length != 0`!

 Why is this problematic?
 Low-level calls to non-contracts (i.e. addresses with no code) will _always return true_!
 See https://evm.codes and check for `call` opcode.

 Why is the check missing?
 Gas optimization...
 Verifying the address' code size on each call when you would only need to do
 it once makes sense.
 */

/// @notice Safe ETH and ERC20 transfer library that gracefully handles missing return values.
/// @author Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/SafeTransferLib.sol)
/// @dev Use with caution! Some functions in this library knowingly create dirty bits at the destination of the free memory pointer.
/// @dev Note that none of the functions in this library check that a token has code at all! That responsibility is delegated to the caller.
library SafeTransferLib {
    /*//////////////////////////////////////////////////////////////
                             ETH OPERATIONS
    //////////////////////////////////////////////////////////////*/

    // @audit Now a small assembly/YUL and low-level EVM lesson.

    function safeTransferETH(address to, uint256 amount) internal {
        bool success;
        /**
         @audit Variables used inside `assembly` blocks need to be declared
                outside of the block.
         */

        assembly {
            // Transfer the ETH and store if it succeeded or not.
            success := call(gas(), to, amount, 0, 0, 0, 0)
            /**
             @audit
             gas()  -> Returns the amount of gas left in the current execution
             call() -> Executes some code a `to` with some args (here none) while also
                       sending some ETH (here none). The execution is allowed to spend
                       some amount of gas (here all gas thats left).
                       We also need to prepare memory area for returns values (here none).

             Remember: Your best fren is https://evm.codes
             */
        }

        require(success, "ETH_TRANSFER_FAILED");
    }

    /*//////////////////////////////////////////////////////////////
                            ERC20 OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function safeTransferFrom(
        ERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        bool success;

        /**
         @audit Some hex conversions:
         0x20 = 32 = 256 bit = 1 word
         0x40 = 64           = 2 words
         */


        assembly {
            /**
             @audit The "free memory pointer" stores a pointer to the
                    current next free memory.

             IMPORTANT:
             The memory is not guaranteed to be zero! Expect dirty bits!

             Q: Whats with the 2 words before [0x00:0x40)?
             A: Thats the "scratch space". It can be used for short-term storage.
                However, the Solidity compiler may override data in it.
                DO NOT DEPEND ON IT!
             */

            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            /**
             @audit                   ^^^^^^^ Whats all this?

             Lets find out:
             $ echo 23b872dd00000000000000000000000000000000000000000000000000000000 | wc -c
             > 65
             (Actually 64, the `echo` command adds a newline thats counted too)

             => 64 => 32 bytes = 1 word
             => (Could have also checked `mstore` docs -> "Stores one word in memory")

             Function selector:
             So that the contract knows which function you want to call.
             Defined as:
             `bytes4(keccak256(<function signature>))`, e.g. `bytes4(keccak256(transferFrom(address,address,uint)))`
              ^^^^^^ => 4 bytes!

             Don't trust, verify:
             $ cast sig "transferFrom(address,address,uint)"
             > 0x23b872dd

             How much data to we need overall?
             => 4 + 32 + 32 + 32 = 100
             => 4 bytes + 96 bytes = 100 bytes !!!
                          ^^ data arguments
                ^ function signature
             */

            /**
             @audit
                     |                   |                   |                   |
                     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
             Got:  0x23b872dd00000000000000000000000000000000000000000000000000000000
                             ^ start here and insert 32 bytes (`from` address).
             */
            mstore(add(freeMemoryPointer, 4), from) // Append the "from" argument.
            /**
             @audit Start at 4 + 32 = 36 and insert 32 bytes (`to` address).
             */
            mstore(add(freeMemoryPointer, 36), to) // Append the "to" argument.
            /**
             @audit Start at 4 + 32 + 32 = 68 and insert 32 bytes (`amount` uint).
             */
            mstore(add(freeMemoryPointer, 68), amount) // Append the "amount" argument.
            /**
             @audit
             Wuhuuu.. All data needed for the call is saved in memory.
             How much data again?
             4 + 32 + 32 + 32 = 100 bytes
             ^   ^^   ^^   ^^
             |   |    |    amount: uint
             |   |    to: address
             |   from: address
             function selector
             */
            /**
             @audit IMPORTANT DISCLAIMER:
             address is actually only 20 bytes! The highest-order bytes are zeros (hopefully XD)
             Example: 0x000000000000000000000000BEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEFBEEF
                        ^ 12 bytes of zeros     ^ Actual address starts here.
             */


            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                /**
                 @audit Lets break this down:
                 or(
                     and(
                         eq(
                             mload(0), => Load scratch space (where we stored the return data)
                             1         => 1 is boolean for TRUE
                         ),            ==> True/1 if call returned true
                         gt(
                             returndatasize(), => The amount of data returned
                             31
                         )                     ==> True/1 if call returned more than 31 bytes (remember: boolean is 32 bytes)
                     ),   ==> True if call returns true and returned more than 31 bytes
                     iszero(
                         returndatasize()
                     ) ==> True if no return data
                 ) ==> True if no return data OR return data is "Solidity's boolean true representation".
                 */

                // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                // @audit ^^ Weird but ok.. The `call()` is executed first, and then the stuff above.
                call(gas(), token, 0, freeMemoryPointer, 100, 0, 32)
                /**
                 @audit     ^^^^^  ^  ^^^^^^^^^^^^^^^^^  ^^^  ^  ^^
                            |      |  |                  |    |  Amount of bytes to copy from the return data
                            |      |  |                  |    Offset for return data to write to memory (scratch space!). (We actually only get a boolean back, but boolean takes 32 bytes too)
                            |      |  |                  Argument size: 4 + 32 + 32 + 32 = 100
                            |      |  Argument Offset, ie where do the arguments start in memory?
                            |      ETH amount to send (in wei)
                            The target contract to call
                 What does `call()` return?
                 => 0 if execution reverted
                 => 1 otherwise
                 */

            ) // @audit => Call does not revert and a) returns no data OR b) return bool true value
        }

        require(success, "TRANSFER_FROM_FAILED");
    }

    function safeTransfer(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), to) // Append the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "TRANSFER_FAILED");
    }

    function safeApprove(
        ERC20 token,
        address to,
        uint256 amount
    ) internal {
        bool success;

        assembly {
            // Get a pointer to some free memory.
            let freeMemoryPointer := mload(0x40)

            // Write the abi-encoded calldata into memory, beginning with the function selector.
            mstore(freeMemoryPointer, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(freeMemoryPointer, 4), to) // Append the "to" argument.
            mstore(add(freeMemoryPointer, 36), amount) // Append the "amount" argument.

            success := and(
                // Set success to whether the call reverted, if not we check it either
                // returned exactly 1 (can't just be non-zero data), or had no return data.
                or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
                // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
                // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
                // Counterintuitively, this call must be positioned second to the or() call in the
                // surrounding and() call or else returndatasize() will be zero during the computation.
                call(gas(), token, 0, freeMemoryPointer, 68, 0, 32)
            )
        }

        require(success, "APPROVE_FAILED");
    }
}

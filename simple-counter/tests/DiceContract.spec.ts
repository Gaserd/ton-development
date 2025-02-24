import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, fromNano } from '@ton/core';
import { DiceContract, Game, Withdraw } from '../wrappers/DiceContract';
import '@ton/test-utils';

describe('Dice', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let dice: SandboxContract<DiceContract>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();

        dice = blockchain.openContract(await DiceContract.fromInit());

        deployer = await blockchain.treasury('deployer');

        const deployResult = await dice.send(
            deployer.getSender(),
            {
                value: toNano('0.05'),
            },
            {
                $$type: 'Deploy',
                queryId: 0n,
            }
        );

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: dice.address,
            deploy: true,
            success: true,
        });

        await dice.send(
            deployer.getSender(),
            {
                value: toNano("500")
            },
            null
        )
    });

    it('should play game', async () => {
        const user = await blockchain.treasury('user');
        const balanceBefore = await user.getBalance();
        console.log("balanceBefore: " + fromNano(balanceBefore))

        const game: Game = {
            $$type: 'Game'
        }

        for (let i = 0; i < 10; i++) {
            await dice.send(
                user.getSender(),
                {
                    value: toNano("100")
                },
                game
            )

            const balanceAfter = await user.getBalance();
            console.log("balanceAfter: " + fromNano(balanceAfter))
        }

        console.log(toNano('0.1'))
    })

    // it('should deploy and receive ton', async () => {
    //     const balance = await dice.getBalance();
    //     console.log(balance)
    // });

    // it('should withdrawal', async () => {
    //     const user = await blockchain.treasury('user'); // new wallet user
    //     const balanceBefore = await user.getBalance();
    //     console.log("balanceBefore: " + balanceBefore)

    //     const withdraw: Withdraw = {
    //         $$type: 'Withdraw',
    //         amount: 1n
    //     }

    //     await dice.send(
    //         user.getSender(),
    //         {
    //             value : toNano("0.2")
    //         },
    //         withdraw
    //     )
    //     const balanceAfter = await user.getBalance();
    //     console.log("Balance after: " + balanceAfter);

    //     expect(balanceBefore).toBeGreaterThanOrEqual(balanceAfter);
    // })

    // it('should withdraw safe', async () => {
    //     const balance = await deployer.getBalance();
    //     console.log('balance - ' + fromNano(balance));
    //     await dice.send(
    //         deployer.getSender(),
    //         {
    //             value : toNano("0.2")
    //         },
    //         "witdraw safe"
    //     )
    //     const balanceAfter = await deployer.getBalance();
    //     console.log('balance - ' + fromNano(balanceAfter));

    //     expect(balanceAfter).toBeGreaterThanOrEqual(balance);

    //     const balanceContract = await dice.getBalance();
    //     console.log('balanceContract - ' + balanceContract);
    //     expect(balanceContract).toBeGreaterThan(0n);
    // })
    // it('should withdraw msg', async () => {
    //     const message: Withdraw = {
    //         $$type : 'Withdraw',
    //         amount : toNano("100")
    //     }
    //     const balance = await deployer.getBalance();
    //     console.log('balance - ' + fromNano(balance));
    //     await dice.send(
    //         deployer.getSender(),
    //         {
    //             value : toNano("0.2")
    //         },
    //         message

    //     )
    //     const balanceAfter = await deployer.getBalance();
    //     console.log('balance - ' + fromNano(balanceAfter));

    //     expect(balanceAfter).toBeGreaterThanOrEqual(balance);

    //     const balanceContract = await dice.getBalance();
    //     console.log('balanceContract - ' + balanceContract);
    //     expect(balanceContract).toBeGreaterThan(0n);
    // })
});
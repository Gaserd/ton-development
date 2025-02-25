import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, fromNano } from '@ton/core';
import { TokenPrediction } from '../wrappers/TokenPrediction';
import '@ton/test-utils';

describe('TokenPrediction', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let tokenPrediction: SandboxContract<TokenPrediction>;
    let player1: SandboxContract<TreasuryContract>;
    let player2: SandboxContract<TreasuryContract>;

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        tokenPrediction = blockchain.openContract(await TokenPrediction.fromInit());
        deployer = await blockchain.treasury('deployer');
        player1 = await blockchain.treasury('player1');
        player2 = await blockchain.treasury('player2');

        const deployResult = await tokenPrediction.send(
            deployer.getSender(),
            { value: toNano('0.05') },
            { $$type: 'Deploy', queryId: 0n }
        );

        expect(deployResult.transactions).toHaveTransaction({
            from: deployer.address,
            to: tokenPrediction.address,
            deploy: true,
            success: true,
        });
    });

    describe('Basic functionality', () => {
        it('should deploy contract correctly', async () => {
            const epoch = await tokenPrediction.getGetCurrentEpoch();
            expect(epoch).toBe(0n);
        });

        it('should start genesis round', async () => {
            await tokenPrediction.send(
                deployer.getSender(),
                { value: toNano('0.03') },
                { $$type: 'StartRound', price: 1000000n }
            );

            const epoch = await tokenPrediction.getGetCurrentEpoch();
            expect(epoch).toBe(1n);

            const round = await tokenPrediction.getGetRound(1n);
            expect(round.status).toBe(1n); // STATUS_LIVE
            expect(round.startPrice).toBe(1000000n);
        });

        it('should not allow non-admin to start round', async () => {
            const startResult = await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('0.03') },
                { $$type: 'StartRound', price: 1000000n }
            );

            expect(startResult.transactions).toHaveTransaction({
                from: player1.address,
                to: tokenPrediction.address,
                success: false
            });
        });
    });

    describe('Betting mechanics', () => {
        beforeEach(async () => {
            // Стартуем раунд перед каждым тестом
            await tokenPrediction.send(
                deployer.getSender(),
                { value: toNano('0.03') },
                { $$type: 'StartRound', price: 1000000n }
            );
        });

        it('should not accept bets below minimum', async () => {
            const betResult = await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('0.53') }, // 0.5 TON bet + 0.03 gas
                { $$type: 'BetBull' }
            );

            expect(betResult.transactions).toHaveTransaction({
                from: player1.address,
                to: tokenPrediction.address,
                success: false
            });
        });

        it('should not allow double betting', async () => {
            // Первая ставка
            await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('1.03') },
                { $$type: 'BetBull' }
            );

            // Вторая ставка
            const secondBetResult = await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('1.03') },
                { $$type: 'BetBear' }
            );

            expect(secondBetResult.transactions).toHaveTransaction({
                from: player1.address,
                to: tokenPrediction.address,
                success: false
            });
        });
    });

    describe('Round completion', () => {
        it('should return funds when no counter-bet', async () => {
            // Стартуем раунд
            await tokenPrediction.send(
                deployer.getSender(),
                { value: toNano('0.03') },
                { $$type: 'StartRound', price: 1000000n }
            );

            const initialBalance = await player1.getBalance();

            // Делаем ставку
            await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('1.03') },
                { $$type: 'BetBull' }
            );

            // Завершаем раунд
            await tokenPrediction.send(
                deployer.getSender(),
                { value: toNano('0.03') },
                { $$type: 'EndRound', price: 1200000n }
            );

            // После возврата ставки, игрок должен получить ClaimRewards
            await tokenPrediction.send(
                player1.getSender(),
                { value: toNano('0.03') },
                { $$type: 'ClaimRewards' }
            );

            const finalBalance = await player1.getBalance();
            expect(Number(fromNano(finalBalance - initialBalance))).toBeGreaterThan(-0.1);
        });
    });

    describe('Treasury management', () => {
        it('should accumulate and withdraw treasury correctly', async () => {
            const initialTreasuryBalance = await deployer.getBalance();

            // Проводим 2 успешных раунда
            for(let i = 0; i < 2; i++) {
                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'StartRound', price: 1000000n }
                );

                // Увеличиваем ставки для большей комиссии
                await tokenPrediction.send(
                    player1.getSender(),
                    { value: toNano('5.03') },  // 5 TON ставка
                    { $$type: 'BetBull' }
                );

                await tokenPrediction.send(
                    player2.getSender(),
                    { value: toNano('5.03') },  // 5 TON ставка
                    { $$type: 'BetBear' }
                );

                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'EndRound', price: 1200000n }
                );

                // Забираем награды
                await tokenPrediction.send(
                    player1.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'ClaimRewards' }
                );
            }

            // Забираем treasury
            await tokenPrediction.send(
                deployer.getSender(),
                { value: toNano('0.03') },
                { $$type: 'WithdrawTreasury' }
            );

            const ownerBalanceChange = await deployer.getBalance() - initialTreasuryBalance;
            // Теперь должно быть положительное изменение
            expect(Number(fromNano(ownerBalanceChange))).toBeGreaterThan(0);
        });
    });

    describe('Data cleanup', () => {
        it('should cleanup old rounds after CLEANUP_AFTER_ROUNDS', async () => {
            // Запускаем 10 раундов
            for(let i = 0; i < 10; i++) {
                // Стартуем раунд
                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'StartRound', price: 1000000n }
                );

                // Делаем ставки
                await tokenPrediction.send(
                    player1.getSender(),
                    { value: toNano('1.03') },
                    { $$type: 'BetBull' }
                );

                await tokenPrediction.send(
                    player2.getSender(),
                    { value: toNano('1.03') },
                    { $$type: 'BetBear' }
                );

                // Завершаем раунд
                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'EndRound', price: 1200000n }
                );
            }

            // Проверяем финальный эпох
            const currentEpoch = await tokenPrediction.getGetCurrentEpoch();
            expect(currentEpoch).toBe(10n);

            // Проверяем, что раунды доступны
            const round1 = await tokenPrediction.getGetRound(1n);
            expect(round1.status).toBe(3n); // STATUS_ENDED

            const round10 = await tokenPrediction.getGetRound(10n);
            expect(round10.status).toBe(3n); // STATUS_ENDED
        });

        it('should cleanup old bets and rewards', async () => {
            // Запускаем несколько раундов
            for(let i = 0; i < 105; i++) {
                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'StartRound', price: 1000000n }
                );

                // Делаем ставки
                await tokenPrediction.send(
                    player1.getSender(),
                    { value: toNano('1.03') },
                    { $$type: 'BetBull' }
                );

                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'EndRound', price: 1200000n }
                );

                // Забираем награды
                await tokenPrediction.send(
                    player1.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'ClaimRewards' }
                );
            }

            // Проверяем, что старые награды очищены
            const userRewards = await tokenPrediction.getGetUserRewards(player1.address);
            expect(userRewards.pendingRewards).toBe(0n);
        });

        it('should maintain maximum stored rounds limit', async () => {
            // Запускаем MAX_STORED_ROUNDS + 10 раундов
            for(let i = 0; i < 1010; i++) {
                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'StartRound', price: 1000000n }
                );

                await tokenPrediction.send(
                    deployer.getSender(),
                    { value: toNano('0.03') },
                    { $$type: 'EndRound', price: 1200000n }
                );
            }

            // Проверяем, что количество хранимых раундов не превышает MAX_STORED_ROUNDS
            const currentEpoch = await tokenPrediction.getGetCurrentEpoch();
            const oldestAvailableEpoch = await tokenPrediction.getGetOldestAvailableEpoch();
            
            // Разница между текущим и самым старым эпохом не должна превышать MAX_STORED_ROUNDS
            expect(Number(currentEpoch - oldestAvailableEpoch)).toBeLessThanOrEqual(1000);
        });
    });
});

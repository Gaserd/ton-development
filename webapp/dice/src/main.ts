import './style.css'
import { TonConnectUI } from '@tonconnect/ui'
import { TonClient, Address, toNano, fromNano, beginCell, storeMessage, Cell } from '@ton/ton'
import { getHttpEndpoint } from "@orbs-network/ton-access"
import { Buffer } from 'buffer'

// @ts-ignore
window.Buffer = Buffer

const tonConnectUI = new TonConnectUI({
  manifestUrl: 'https://raw.githubusercontent.com/ton-connect/demo-dapp/refs/heads/master/public/tonconnect-manifest.json',
  buttonRootId: 'ton-connect'
})

tonConnectUI.onStatusChange(async wallet => {
  if (wallet) {

    const gameAddress = 'EQCYE1PJNSxQ_muojGZKUsWD7A9M1qGq1uvtp9ca_BANuis6'
    const endpoint = await getHttpEndpoint();

    const client = new TonClient({ endpoint });

    async function getGameBalance() {
      const address = Address.parse(gameAddress)
      const result = await client.runMethod(address, 'balance')
      const message = fromNano(result.stack.readBigNumber())
      console.log('Message:', message + ' TON');

    }

    document.getElementById('send-trx')!.onclick = async () => {

      const body = beginCell()
        .storeUint(0, 32) // это идентификатор Game
        .storeUint(1, 32)
        .endCell();

      let tx = await tonConnectUI.sendTransaction({
        validUntil: Math.floor(Date.now() / 1000) + 60,
        messages: [
          {
            amount: toNano('0.1').toString(),
            address: gameAddress,
            payload: body.toBoc().toString('base64')
          }
        ]
      })

      console.log(tx)
    }
  }
});
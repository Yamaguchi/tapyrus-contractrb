# frozen_string_literal: true

require 'securerandom'

module Glueby
  module Internal
    class Wallet
      # ActiveRecordWalletAdapter
      #
      # This class represents a wallet adapter that use Active Record to manage wallet and utxos.
      # To use this wallet adapter, you should do the following steps:
      #
      # (1) Generate migrations for wallets, keys, utxos tables.
      # The generator `glueby:contract:wallet_adapter` is available for migration.
      # ```
      # rails g glueby:contract:wallet_adapter
      # ```
      # this generator generates 3 files to create tables used by ActiveRecordWalletAdatper.
      # then, migrate them
      # ```
      # $ rails db:migrate
      # ```
      #
      # (2) Add configuration for activerecord
      # ```
      # config = {adapter: 'activerecord', schema: 'http', host: '127.0.0.1', port: 12381, user: 'user', password: 'pass'}
      # Glueby::Wallet.configure(config)
      # ```
      #
      # (3) Generate wallet and receive address
      # ```
      # alice_wallet = Glueby::Wallet.create
      # address = alice_wallet.internal_wallet.receive_address
      # ```
      # `Glueby::Internal::Wallet#receive_address` returns Base58 encoded Tapyrus address like '1CY6TSSARn8rAFD9chCghX5B7j4PKR8S1a'.
      #
      # (4) Send TPC to created address and import into wallet.
      # In general, ActiveRecordWalletAdapter handle only utxos generated by glueby.
      # So, to start to use wallet, some external utxo should be imported  into the wallet first.
      # This step should be done by external transaction without Glueby::Wallet, such as 'sendtoaddress' or 'generatetoaddress' RPC command of Tapyrus Core
      # ```
      # $ tapyrus-cli sendtoaddress 1CY6TSSARn8rAFD9chCghX5B7j4PKR8S1a 1
      # 1740af9f65ffd8537bdd06ccfa911bf1f4d6833222807d29c99d72b47838917d
      # ```
      #
      # then, import into wallet by rake task `glueby:contract:wallet_adapter:import_tx` or `glueby:contract:wallet_adapter:import_block`
      # ```
      # $ rails "glueby:contract:wallet_adapter:import_tx[1740af9f65ffd8537bdd06ccfa911bf1f4d6833222807d29c99d72b47838917d]""
      # ```
      #
      # (5) You are ready to use ActiveRecordWalletAdatper, check `Glueby::Internal::Wallet#list_unspent` or `Glueby::Wallet#balances`
      # ```
      # alice_wallet = Glueby::Wallet.create
      # alice_wallet.balances
      # ```
      class ActiveRecordWalletAdapter < AbstractWalletAdapter
        def create_wallet(wallet_id = nil)
          wallet_id = SecureRandom.hex(16) unless wallet_id
          begin
            AR::Wallet.create!(wallet_id: wallet_id)
          rescue ActiveRecord::RecordInvalid => _
            raise Errors::WalletAlreadyCreated, "wallet_id '#{wallet_id}' is already exists"
          end
          wallet_id
        end

        def delete_wallet(wallet_id)
          AR::Wallet.destroy_by(wallet_id: wallet_id)
        end

        def load_wallet(wallet_id)
          raise Errors::WalletNotFound, "Wallet #{wallet_id} does not found" unless AR::Wallet.where(wallet_id: wallet_id).exists?
        end

        def unload_wallet(wallet_id)
        end

        def wallets
          AR::Wallet.all.map(&:wallet_id).sort
        end

        def balance(wallet_id, only_finalized = true)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          utxos = wallet.utxos
          utxos = utxos.where(status: :finalized) if only_finalized
          utxos.sum(&:value)
        end

        def list_unspent(wallet_id, only_finalized = true, label = nil)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          utxos = wallet.utxos
          utxos = utxos.where(status: :finalized) if only_finalized
          utxos = utxos.where(label: label) if label
          utxos.map do |utxo|
            {
              txid: utxo.txid,
              vout: utxo.index,
              script_pubkey: utxo.script_pubkey,
              color_id: utxo.color_id,
              amount: utxo.value,
              finalized: utxo.status == 'finalized'
            }
          end
        end

        def sign_tx(wallet_id, tx, prevtxs = [], sighashtype: Tapyrus::SIGHASH_TYPE[:all])
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          wallet.sign(tx, prevtxs, sighashtype: sighashtype)
        end

        def broadcast(wallet_id, tx)
          ::ActiveRecord::Base.transaction do
            AR::Utxo.destroy_for_inputs(tx)
            AR::Utxo.create_or_update_for_outputs(tx, status: :broadcasted)
            Glueby::Internal::RPC.client.sendrawtransaction(tx.to_hex)
          end
        end

        def receive_address(wallet_id, label = nil)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          key = wallet.keys.create(purpose: :receive, label: label || '')
          key.address
        end

        def change_address(wallet_id)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          key = wallet.keys.create(purpose: :change)
          key.address
        end

        def create_pubkey(wallet_id)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          key = wallet.keys.create(purpose: :receive)
          Tapyrus::Key.new(pubkey: key.public_key)
        end

        def get_addresses(wallet_id, label = nil)
          wallet = AR::Wallet.find_by(wallet_id: wallet_id)
          keys = wallet.keys
          keys = keys.where(label: label) if label
          keys.map(&:address)
        end
      end
    end
  end
end

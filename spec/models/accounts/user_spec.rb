# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Accounts::User, type: :model do
  subject { build(:accounts_user) }

  # ============================================
  # Factory Tests
  # ============================================
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:accounts_user)).to be_valid
    end

    it 'can be persisted' do
      user = create(:accounts_user)
      expect(user).to be_persisted
      expect(user.address).to be_present
    end
  end

  # ============================================
  # Validations
  # ============================================
  describe 'validations' do
    it { is_expected.to validate_presence_of(:address) }

    describe 'address uniqueness' do
      it 'is invalid with duplicate address (case insensitive)' do
        create(:accounts_user, address: '0xABC123')
        duplicate = build(:accounts_user, address: '0xabc123')
        expect(duplicate).not_to be_valid
      end

      it 'allows different addresses' do
        create(:accounts_user, address: '0xABC123')
        different = build(:accounts_user, address: '0xDEF456')
        expect(different).to be_valid
      end
    end
  end

  # ============================================
  # Callbacks
  # ============================================
  describe 'callbacks' do
    describe 'before_save :downcase_address' do
      it 'converts address to lowercase before saving' do
        user = create(:accounts_user, address: '0xABCDEF123456')
        expect(user.reload.address).to eq('0xabcdef123456')
      end

      it 'handles already lowercase addresses' do
        user = create(:accounts_user, address: '0xabcdef123456')
        expect(user.address).to eq('0xabcdef123456')
      end

      it 'handles mixed case addresses' do
        user = create(:accounts_user, address: '0xAbCdEf123456')
        expect(user.address).to eq('0xabcdef123456')
      end
    end
  end

  # ============================================
  # Address Format
  # ============================================
  describe 'address format' do
    it 'accepts Ethereum-style addresses' do
      user = build(:accounts_user, address: '0x742d35Cc6634C0532925a3b844Bc454e4438f44e')
      expect(user).to be_valid
    end

    it 'stores address in lowercase' do
      user = create(:accounts_user, address: '0x742D35CC6634C0532925A3B844BC454E4438F44E')
      expect(user.address).to eq('0x742d35cc6634c0532925a3b844bc454e4438f44e')
    end
  end
end

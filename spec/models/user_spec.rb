# frozen_string_literal: true

# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/.
#
# Copyright (c) 2018 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.

require "rails_helper"
require 'bigbluebutton_api'

describe User, type: :model do
  before do
    @user = create(:user)
    @secure_pwd = "#{Faker::Internet.password(min_length: 8, mix_case: true, special_characters: true)}1aB"
    @insecure_pwd = Faker::Internet.password(min_length: 8, mix_case: true).to_s
  end

  context 'validations' do
    it { should validate_presence_of(:name) }
    it { should validate_length_of(:name).is_at_most(256) }
    it { should_not allow_value("https://www.bigbluebutton.org").for(:name) }

    it { should validate_presence_of(:provider) }

    it { should validate_uniqueness_of(:email).scoped_to(:provider).case_insensitive }
    it { should validate_length_of(:email).is_at_most(256) }
    it { should allow_value("valid@email.com").for(:email) }
    it { should_not allow_value("invalid_email").for(:email) }
    it { should allow_value(true).for(:accepted_terms) }
    it {
      expect(@user.greenlight_account?).to be
      allow(Rails.configuration).to receive(:terms).and_return("something")
      should_not allow_value(false).for(:accepted_terms)
      allow(Rails.configuration).to receive(:terms).and_return(false)
      should allow_value(false).for(:accepted_terms)
    }

    it { should allow_value("valid.jpg").for(:image) }
    it { should allow_value("valid.png").for(:image) }
    it { should allow_value("random_file.txt").for(:image) }
    it { should allow_value("", nil).for(:image) }

    it "should convert email to downcase on save" do
      user = create(:user, email: "DOWNCASE@DOWNCASE.COM")
      expect(user.email).to eq("downcase@downcase.com")
    end
    context 'is greenlight account' do
      before { allow(subject).to receive(:greenlight_account?).and_return(true) }
      it { should validate_length_of(:password).is_at_least(8) }
      it { should validate_confirmation_of(:password) }
      it "should validate password complexity" do
        @user.update(password: @secure_pwd, password_confirmation: @secure_pwd)
        expect(@user).to be_valid
        @user.update(password: @insecure_pwd, password_confirmation: @insecure_pwd)
        expect(@user).to be_invalid
      end
    end

    context 'is not greenlight account' do
      before { allow(subject).to receive(:greenlight_account?).and_return(false) }
      it { should_not validate_presence_of(:password) }
    end
  end

  context 'associations' do
    it { should belong_to(:main_room).class_name("Room").with_foreign_key("room_id") }
    it { should have_many(:rooms) }
  end

  context '#initialize_main_room' do
    it 'creates random uid and main_room' do
      expect(@user.uid).to_not be_nil
      expect(@user.main_room).to be_a(Room)
    end
  end

  context "#to_param" do
    it "uses uid as the default identifier for routes" do
      expect(@user.to_param).to eq(@user.uid)
    end
  end

  unless Rails.configuration.omniauth_bn_launcher
    context '#from_omniauth' do
      let(:auth) do
        {
          "uid" => "123456789",
          "provider" => "twitter",
          "info" => {
            "name" => "Test Name",
            "nickname" => "username",
            "email" => "test@example.com",
            "image" => "example.png",
          },
        }
      end

      it "should create user from omniauth" do
        expect do
          user = User.from_omniauth(auth)

          expect(user.name).to eq("Test Name")
          expect(user.email).to eq("test@example.com")
          expect(user.image).to eq("example.png")
          expect(user.provider).to eq("twitter")
          expect(user.social_uid).to eq("123456789")
        end.to change { User.count }.by(1)
      end
    end
  end

  context '#name_chunk' do
    it 'properly finds the first three characters of the users name' do
      user = create(:user, name: "Example User")
      expect(user.name_chunk).to eq("exa")
    end
  end

  context '#ordered_rooms' do
    it 'correctly orders the users rooms' do
      user = create(:user)
      room1 = create(:room, owner: user)
      room2 = create(:room, owner: user)
      room3 = create(:room, owner: user)
      room4 = create(:room, owner: user)

      room4.update_attributes(sessions: 1, last_session: "2020-02-24 19:52:57")
      room3.update_attributes(sessions: 1, last_session: "2020-01-25 19:52:57")
      room2.update_attributes(sessions: 1, last_session: "2019-09-05 19:52:57")
      room1.update_attributes(sessions: 1, last_session: "2015-02-24 19:52:57")

      rooms = user.ordered_rooms
      expect(rooms[0]).to eq(user.main_room)
      expect(rooms[1]).to eq(room4)
      expect(rooms[2]).to eq(room3)
      expect(rooms[3]).to eq(room2)
      expect(rooms[4]).to eq(room1)
    end
  end

  context 'password reset' do
    it 'creates token and respective reset digest' do
      user = create(:user)

      expect(user.create_reset_digest).to be_truthy
    end

    it 'correctly verifies the token' do
      user = create(:user)
      token = user.create_reset_digest
      expect(User.exists?(reset_digest: User.hash_token(token))).to be true
    end

    it 'verifies if password reset link expired' do
      user = create(:user)
      user.create_reset_digest

      expired = user.password_reset_expired?
      expect(expired).to be_in([true, false])
    end
  end

  context '#roles' do
    it "defaults the user to a user role" do
      expect(@user.has_role?(:user)).to be true
    end

    it "does not give the user an admin role" do
      expect(@user.has_role?(:admin)).to be false
    end

    it "returns true if the user is an admin of another" do
      allow(Rails.configuration).to receive(:loadbalanced_configuration).and_return(true)
      allow_any_instance_of(User).to receive(:greenlight_account?).and_return(true)

      @admin = create(:user, provider: @user.provider)
      @admin.set_role :admin

      expect(@admin.admin_of?(@user, "can_manage_users")).to be true

      @super_admin = create(:user, provider: "test")
      @super_admin.set_role :super_admin

      expect(@super_admin.admin_of?(@user, "can_manage_users")).to be true
    end

    it "returns false if the user is NOT an admin of another" do
      @admin = create(:user)

      expect(@admin.admin_of?(@user, "can_manage_users")).to be false
    end

    it "should get the highest priority role" do
      @admin = create(:user, provider: @user.provider)
      @admin.set_role :admin

      expect(@admin.role.name).to eq("admin")
    end

    it "should add the role if the user doesn't already have the role" do
      @admin = create(:user, provider: @user.provider)
      @admin.set_role :admin

      expect(@admin.has_role?(:admin)).to eq(true)
    end

    it "has_role? should return false if the user doesn't have the role" do
      expect(@user.has_role?(:admin)).to eq(false)
    end

    it "has_role? should return true if the user has the role" do
      @admin = create(:user, provider: @user.provider)
      @admin.set_role :admin

      expect(@admin.has_role?(:admin)).to eq(true)
    end

    it "with_role should return all users with the role" do
      @admin1 = create(:user, provider: @user.provider)
      @admin2 = create(:user, provider: @user.provider)
      @admin1.set_role :admin
      @admin2.set_role :admin

      expect(User.with_role(:admin).count).to eq(2)
    end

    it "without_role should return all users without the role" do
      @admin1 = create(:user, provider: @user.provider)
      @admin2 = create(:user, provider: @user.provider)
      @admin1.set_role :admin
      @admin2.set_role :admin

      expect(User.without_role(:admin).count).to eq(1)
    end
  end

  context 'blank email' do
    it "allows a blank email if the provider is not greenlight" do
      allow_any_instance_of(User).to receive(:greenlight_account?).and_return(false)

      user = create(:user, email: "", provider: "ldap")
      expect(user.valid?).to be true
    end

    it "does not allow a blank email if the provider is greenlight" do
      expect { create(:user, email: "", provider: "greenlight") }
        .to raise_exception(ActiveRecord::RecordInvalid, "Validation failed: Email can't be blank")
    end
  end

  context "#locked_out?" do
    it "returns true if there has been more than 5 login attempts in the past 24 hours" do
      @user.update(failed_attempts: 6, last_failed_attempt: 10.hours.ago)
      expect(@user.locked_out?).to be true
    end

    it "returns false if there has been less than 6 login attempts in the past 24 hours" do
      @user.update(failed_attempts: 3, last_failed_attempt: 10.hours.ago)
      expect(@user.locked_out?).to be false
    end

    it "returns false if the last failed attempt was older than 24 hours" do
      @user.update(failed_attempts: 6, last_failed_attempt: 30.hours.ago)
      expect(@user.locked_out?).to be false
    end

    it "resets the counter if the last failed attempt was over 24 hours ago" do
      @user.update(failed_attempts: 3, last_failed_attempt: 30.hours.ago)

      expect(@user.locked_out?).to be false
      expect(@user.reload.failed_attempts).to eq(0)
    end
  end

  context 'class methods' do
    context "#secure_password?" do
      it "should return true for secure passwords" do
        expect(User.secure_password?(@secure_pwd)).to be
      end
      it "should return false for insecure passwords" do
        expect(User.secure_password?(@insecure_pwd)).not_to be
      end
    end
  end

  context "#without_terms_acceptance" do
    before {
      @user.update accepted_terms: false
      allow(Rails.configuration).to receive(:terms).and_return("something")
    }
    it "runs blocks with terms acceptance validation disabled" do
      expect(@user.accepted_terms).not_to be
      expect(@user.valid?).not_to be
      @user.without_terms_acceptance { expect(@user.valid?).to be }
    end
  end
end

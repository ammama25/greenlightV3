# frozen_string_literal: true

class AddSecurePasswordToUsers < ActiveRecord::Migration[5.2]
  def change
    add_column :users, :secure_password, :boolean, null: false, default: false
  end
end

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

module Authenticator
  extend ActiveSupport::Concern

  # Logs a user into GreenLight.
  def login(user)
    migrate_twitter_user(user)

    session[:user_id] = user.id
    # Upon login the session metadata activated_at has to match to login event timestamp.
    session[:activated_at] = user.last_login.to_i if user.without_terms_acceptance { user.update(last_login: Time.zone.now) }
    logger.info("Support: #{user.email} has successfully logged in.")
    # If there are not terms, or the user has accepted them, check for email verification
    if !Rails.configuration.terms || user.accepted_terms
      check_email_verified(user)
    else
      redirect_to terms_path
    end
  end

  # If email verification is disabled, or the user has verified, go to their room
  def check_email_verified(user)
    # Admin users should be redirected to the admin page
    if user.has_role? :super_admin
      redirect_to admins_path
    elsif user.activated?
      # Dont redirect to any of these urls
      dont_redirect_to = [root_url, signin_url, ldap_signin_url, ldap_callback_url, signup_url, unauthorized_url,
                          internal_error_url, not_found_url]

      unless ENV['OAUTH2_REDIRECT'].nil?
        dont_redirect_to.push(File.join(ENV['OAUTH2_REDIRECT'], "auth", "openid_connect", "callback"))
      end

      valid_url = cookies[:return_to] && URI.parse(cookies[:return_to]).host == URI.parse(request.original_url).host

      url = if cookies[:return_to] && valid_url && !dont_redirect_to.include?(cookies[:return_to])
        cookies[:return_to]
      elsif user.role.get_permission("can_create_rooms")
        user.main_room
      else
        cant_create_rooms_path
      end

      # Delete the cookie if it exists
      cookies.delete :return_to if cookies[:return_to]

      redirect_to url
    else
      session[:user_id] = nil
      user.create_activation_token
      redirect_to account_activation_path(digest: user.activation_digest)
    end
  end

  def ensure_unauthenticated_except_twitter
    redirect_to current_user.main_room || root_path if current_user && params[:old_twitter_user_id].nil?
  end

  # Logs current user out of GreenLight.
  def logout
    session.delete(:user_id) if current_user
  end

  # Check if the user is using local accounts
  def auth_changed_to_local?(user)
    Rails.configuration.loadbalanced_configuration && user.social_uid.present? && allow_greenlight_accounts?
  end

  # Check if the user exists under the same email with no social uid and that social accounts are allowed
  def auth_changed_to_social?(email)
    return true if Rails.configuration.social_switching

    Rails.configuration.loadbalanced_configuration &&
      User.exists?(email: email, provider: @user_domain) &&
      !allow_greenlight_accounts?
  end

  # Sets the initial user role based on the email mapping
  def initial_user_role(email)
    mapping = @settings.get_value("Email Mapping")
    return "user" unless mapping.present?

    mapping.split(",").each do |map|
      email_role = map.split("=")
      return email_role[1] if email.ends_with?(email_role[0])
    end

    "user" # default to user if role not found
  end

  private

  # Migrates all of the twitter users rooms to the new account
  def migrate_twitter_user(user)
    if !session["old_twitter_user_id"].nil? && user.provider != "twitter"
      old_user = User.find(session["old_twitter_user_id"])

      old_user.rooms.each do |room|
        room.owner = user

        room.name = "Old #{room.name}" if room.id == old_user.main_room.id

        room.save!
      end

      # Query for the old user again so the migrated rooms don't get deleted
      old_user.reload
      old_user.destroy!

      session["old_twitter_user_id"] = nil

      flash[:success] = I18n.t("registration.deprecated.merge_success")
    end
  end
end

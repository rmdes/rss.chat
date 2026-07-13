-- prefs must never be NULL: rssnetwork.js buildFeedForUser crashes the server
-- when a user who has never saved prefs publishes their first post.
update users set prefs = json_object() where prefs is null;
alter table users modify prefs json not null default (json_object());

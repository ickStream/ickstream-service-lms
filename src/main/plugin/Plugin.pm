# Copyright (c) 2013, ickStream GmbH
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of ickStream nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL LOGITECH, INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package Plugins::IckStreamPlugin::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::JSONRPC;

use HTTP::Status qw(RC_OK);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Slim::Web::HTTP;
use HTTP::Status qw(RC_MOVED_TEMPORARILY RC_NOT_FOUND);
use Slim::Utils::Compress;
use POSIX qw(floor);
use Crypt::Tea;

use Plugins::IckStreamPlugin::Settings;
use Plugins::IckStreamPlugin::ContentAccessServer;
use Plugins::IckStreamPlugin::ContentAccessService;
use Plugins::IckStreamPlugin::LocalServiceManager;
use Plugins::IckStreamPlugin::CloudServiceManager;
use Plugins::IckStreamPlugin::PlayerServer;
use Plugins::IckStreamPlugin::PlayerService;
use Plugins::IckStreamPlugin::BrowseManager;
use Plugins::IckStreamPlugin::ProtocolHandler;
use Plugins::IckStreamPlugin::PlayerManager;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM',
});

my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

$prefs->migrate( 1, sub {
	$prefs->set('orderAlbumsForArtist', 'by_title');
	1;
});
$prefs->migrate( 2, sub {
	$prefs->set('daemonPort',$serverPrefs->get('httpport')+6);
	$prefs->set('squeezePlayPlayersEnabled',0);
	1;
});
$prefs->migrate( 3, sub {
	$prefs->set('squeezePlayPlayersEnabled',1);
	1;
});

my $nextRequestedLocalServiceId = 2;

sub initPlugin {
	my $class = shift;

	Slim::Player::ProtocolHandlers->registerHandler(
		ickstream => 'Plugins::IckStreamPlugin::ProtocolHandler'
	);

	my $self = $class->SUPER::initPlugin(
		tag => 'ickstream',
		feed => \&Plugins::IckStreamPlugin::BrowseManager::topLevel,
		is_app => 1,
		menu => 'radios',
		weight => 1
		);
	
	Plugins::IckStreamPlugin::ContentAccessService::init($class);
	Plugins::IckStreamPlugin::BrowseManager::init();
	Plugins::IckStreamPlugin::Settings->new($class);
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&startServers,$class);
	Slim::Control::Request::addDispatch(['ickstream','player','?'], [1, 1, 0, \&Plugins::IckStreamPlugin::PlayerManager::playerEnabledQuery]);

	Slim::Control::Request::subscribe(\&Plugins::IckStreamPlugin::PlayerManager::playerChange,[['client']]);
	if(!main::ISWINDOWS) {
		Slim::Control::Request::subscribe(\&trackEnded,[['playlist'],['newsong']]);
		Slim::Control::Request::subscribe(\&otherPlaylist,[['playlist'],['clear','loadtracks','playtracks','play','loadalbum','playalbum']]);
	}
}


sub startServers {
	my $timer = shift;
	my $class = shift;
	
	if(!main::ISWINDOWS) {
		Plugins::IckStreamPlugin::ContentAccessServer->start($class);
		Plugins::IckStreamPlugin::PlayerServer->start($class);
	}else {
		Plugins::IckStreamPlugin::PlayerManager::start($class);
	}
}

sub shutdownPlugin {
	if(!main::ISWINDOWS) {
		Plugins::IckStreamPlugin::ContentAccessServer->stop;
		Plugins::IckStreamPlugin::PlayerServer->stop;
	}
}

sub getDisplayName { 'PLUGIN_ICKSTREAM' }

sub webPages {
	my $class = shift;

	return unless main::WEBUI;

	Slim::Web::Pages->addRawFunction('IckStreamPlugin/ContentAccessService/jsonrpc', \&Plugins::IckStreamPlugin::ContentAccessService::handleJSONRPC);
	Slim::Web::Pages->addRawFunction('IckStreamPlugin/music/.*', \&Plugins::IckStreamPlugin::ContentAccessService::handleStream);
	Slim::Web::Pages->addRawFunction('IckStreamPlugin/PlayerService/jsonrpc', \&Plugins::IckStreamPlugin::PlayerService::handleJSONRPC);
	Slim::Web::Pages->addRawFunction('IckStreamPlugin/discovery', \&Plugins::IckStreamPlugin::LocalServiceManager::handleDiscoveryJSON);
	Slim::Web::Pages->addPageFunction('IckStreamPlugin/settings/authenticationCallback\.html', \&Plugins::IckStreamPlugin::Settings::handleAuthenticationFinished);
	Slim::Web::HTTP::addCloseHandler(\&Plugins::IckStreamPlugin::JsonHandler::handleClose);

	$class->SUPER::webPages();
}

sub getNextRequestId {
	$nextRequestedLocalServiceId++;
	return $nextRequestedLocalServiceId;
}


sub otherPlaylist {
	# These are the two passed parameters
	my $request=shift;
	my $player = $request->client();

	if(defined($request->source())) {
		$log->debug("Entering otherPlaylist due to ".$request->getRequestString()." triggered by ".$request->source());
	}else {
		$log->debug("Entering otherPlaylist due to ".$request->getRequestString());
	}
	if(!defined($request->source()) || $request->source() ne 'PLUGIN_ICKSTREAM') {
		my @empty = ();
		Plugins::IckStreamPlugin::PlaybackQueueManager::setPlaybackQueue($player,\@empty);
		@empty = ();
		Plugins::IckStreamPlugin::PlaybackQueueManager::setOriginalPlaybackQueue($player,\@empty);
		
		my $playerStatus = $prefs->get('playerstatus_'.$player->id);
		$playerStatus->{'playbackQueuePos'} = undef;
		$playerStatus->{'track'} = undef;
		$prefs->set('playerstatus_'.$player->id,$playerStatus);
		Plugins::IckStreamPlugin::PlayerService::sendPlaybackQueueChangedNotification($player);
		Plugins::IckStreamPlugin::PlayerService::sendPlayerStatusChangedNotification($player);
	}
}

sub trackEnded {
	$log->debug("Entering trackEnded\n");
	# These are the two passed parameters
	my $request=shift;
	my $player = $request->client();
	
	if(defined($player)) {
		my $notification = Plugins::IckStreamPlugin::PlayerService::refreshCurrentPlaylist($player);
		if($notification) {
			Plugins::IckStreamPlugin::PlayerService::sendPlayerStatusChangedNotification($player);
		}
	}
}

1;

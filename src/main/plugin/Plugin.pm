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
use Plugins::IckStreamPlugin::PlayerServiceCLI;
use Plugins::IckStreamPlugin::BrowseManager;
use Plugins::IckStreamPlugin::ProtocolHandler;
use Plugins::IckStreamPlugin::LocalProtocolHandler;
use Plugins::IckStreamPlugin::PlayerManager;
use Plugins::IckStreamPlugin::LicenseManager;

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
$prefs->migrate( 4, sub {
	$prefs->set('confirmedLicenses',{});
	1;
});
$prefs->migrate( 5, sub {
	my $cloudCoreUrl = $prefs->get('cloudCoreUrl');
	if(defined($cloudCoreUrl) && $cloudCoreUrl eq 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc') {
		$prefs->set('https://api.ickstream.com/ickstream-cloud-core/jsonrpc');
	}
	my $clients = $prefs->get('players');
	my $clientPrefs = {};
	foreach my $clientId (values %$clients) {
		if($prefs->get('player_'.$clientId)) {
			if(!defined($clientPrefs->{$clientId})) {
				$clientPrefs->{$clientId} = Slim::Utils::Prefs::Client->new($prefs,$clientId);
			}
			Slim::Utils::Misc::msg("Write playerConfiguration for $clientId");
			$clientPrefs->{$clientId}->set('playerConfiguration',$prefs->get('player_'.$clientId));
			my $playerConfiguration = $clientPrefs->{$clientId}->get('playerConfiguration');
			my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'};
			if(defined($cloudCoreUrl) && $cloudCoreUrl eq 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc') {
				$playerConfiguration->{'cloudCoreUrl'} = 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
				$clientPrefs->{$clientId}->set('playerConfiguration',$playerConfiguration);
			}
			$prefs->remove('player_'.$clientId);
		}
		if($prefs->get('playerstatus_'.$clientId)) {
			if(!defined($clientPrefs->{$clientId})) {
				$clientPrefs->{$clientId} = Slim::Utils::Prefs::Client->new($prefs,$clientId);
			}
			Slim::Utils::Misc::msg("Write playerStatus for $clientId");
			$clientPrefs->{$clientId}->set('playerStatus',$prefs->get('playerstatus_'.$clientId));
			$prefs->remove('playerstatus_'.$clientId);
		}
	}
	1;
});
$prefs->migrate( 6, sub {
	$prefs->remove('squeezePlayPlayersEnabled');
	1;
});
$prefs->migrate( 7, sub {
	if(defined($prefs->get('applicationId'))) {
		$prefs->set('applicationId', Crypt::Tea::encrypt($prefs->get('applicationId'),$serverPrefs->get('server_uuid')));
	}
	1;
});

$prefs->migrate( 8, sub {
	if(defined($prefs->get('applicationId'))) {
		$prefs->remove('applicationId');
	}
	1;
});
$prefs->migrate( 9, sub {
	if(defined($prefs->get('accessToken'))) {
		$prefs->remove('accessToken');
	}
	1;
});
$prefs->migrate( 10, sub {
	if(defined($prefs->get('cloudCoreUrl'))) {
		if($prefs->get('cloudCoreUrl') eq 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc' ||
			$prefs->get('cloudCoreUrl') eq 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc') {
				
			$prefs->remove('cloudCoreUrl');	
		}
	}
	1;
});
$prefs->migrate( 11, sub {
	$prefs->set('proxiedStreamingForHires', 1);
	1;
});


$prefs->migrateClient(1, sub {
	my ($clientPrefs, $client) = @_;
	
	if(defined($clientPrefs->get('playerConfiguration')) && defined($clientPrefs->get('playerConfiguration')->{'applicationId'})) {
		my $playerConfiguration = $clientPrefs->get('playerConfiguration');
		$playerConfiguration->{'applicationId'} = Crypt::Tea::encrypt($playerConfiguration->{'applicationId'},$serverPrefs->get('server_uuid'));
		$clientPrefs->set('playerConfiguration', $playerConfiguration);
	}
	1;
});

$prefs->migrateClient(2, sub {
	my ($clientPrefs, $client) = @_;
	
	if(defined($clientPrefs->get('playerConfiguration')) && defined($clientPrefs->get('playerConfiguration')->{'applicationId'})) {
		my $playerConfiguration = $clientPrefs->get('playerConfiguration');
		delete $playerConfiguration->{'applicationId'};
		$clientPrefs->set('playerConfiguration', $playerConfiguration);
	}
	1;
});

$prefs->migrateClient(3, sub {
	my ($clientPrefs, $client) = @_;
	
	if(defined($clientPrefs->get('playerConfiguration')) && defined($clientPrefs->get('playerConfiguration')->{'cloudCoreUrl'})) {
		my $playerConfiguration = $clientPrefs->get('playerConfiguration');
		if($playerConfiguration->{'cloudCoreUrl'} eq 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc' ||
			$playerConfiguration->{'cloudCoreUrl'} eq 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc') {

			delete $playerConfiguration->{'cloudCoreUrl'};
			$clientPrefs->set('playerConfiguration', $playerConfiguration);
		}
	}
	1;
});

my $nextRequestedLocalServiceId = 2;

sub initPlugin {
	my $class = shift;
	${Plugins::IckStreamPlugin::Configuration::HOST} = $class->_pluginDataFor('apiHost');
	Slim::Player::ProtocolHandlers->registerHandler(
		ickstream => 'Plugins::IckStreamPlugin::ProtocolHandler'
	);
	Slim::Player::ProtocolHandlers->registerHandler(
		ickstreamlocal => 'Plugins::IckStreamPlugin::LocalProtocolHandler'
	);

	my $self = $class->SUPER::initPlugin(
		tag => 'ickstream',
		feed => \&Plugins::IckStreamPlugin::BrowseManager::topLevel,
		is_app => 1,
		menu => 'radios',
		weight => 1
		);
	
	Plugins::IckStreamPlugin::Settings->new($class);
	Plugins::IckStreamPlugin::ContentAccessService::init($class);
	Plugins::IckStreamPlugin::LocalServiceManager::init($class);
	
	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&startServers,$class);
	Slim::Control::Request::addDispatch(['ickstream','player','?'], [1, 1, 0, \&Plugins::IckStreamPlugin::PlayerManager::playerEnabledQuery]);
	Plugins::IckStreamPlugin::PlayerServiceCLI::init();
	Plugins::IckStreamPlugin::LicenseManager::init();

	Slim::Control::Request::subscribe(\&Plugins::IckStreamPlugin::PlayerManager::playerChange,[['client']]);
	Slim::Control::Request::subscribe(\&Plugins::IckStreamPlugin::BrowseManager::playerChange,[['client']]);
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
	Slim::Web::Pages->addPageFunction('IckStreamPlugin/license\.html', \&Plugins::IckStreamPlugin::LicenseManager::showLicense);
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
		
		my $playerStatus = $prefs->client($player)->get('playerStatus');
		$playerStatus->{'playbackQueuePos'} = undef;
		$playerStatus->{'track'} = undef;
		$prefs->client($player)->set('playerStatus',$playerStatus);
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

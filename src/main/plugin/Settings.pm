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

package Plugins::IckStreamPlugin::Settings;


use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Plugins::IckStreamPlugin::PlayerManager;

use Crypt::Tea;

my $log = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $KEY = undef;

sub new {
        my $class = shift;
        my $plugin = shift;

		$KEY = Slim::Utils::PluginManager->dataForPlugin($plugin)->{'id'};
        $class->SUPER::new();
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('ICKSTREAM');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/IckStreamPlugin/settings/basic.html');
}

sub prefs {
	return ($prefs, 'orderAlbumsForArtist', 'daemonPort', 'squeezePlayPlayersEnabled');
}

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	if ($serverPrefs->get('authorize')) {
		$params->{'authorize'} = 1
	}
	
	my $serverIP = Slim::Utils::IPDetect::IP();
	my $port = $serverPrefs->get('httpport');
	my $serverUrl = "http://".$serverIP.":".$port."/plugins/IckStreamPlugin/settings/authenticationCallback.html";

	my $cloudCoreUrl = $prefs->get('cloudCoreUrl') || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
	my $authenticationUrl = $cloudCoreUrl;
	$authenticationUrl =~ s/^(https?:\/\/.*?)\/.*/\1/;
	$params->{'authenticationUrl'} = $authenticationUrl.'/ickstream-cloud-core/oauth?redirect_uri='.$serverUrl.'&client_id=C5589EF9-9C28-4556-942A-765E698215F1';
        
	if ($params->{'saveSettings'} && $params->{'pref_password'}) {
		my $val = $params->{'pref_password'};
		if ($val ne $params->{'pref_password_repeat'}) {
			$params->{'warning'} .= Slim::Utils::Strings::string('SETUP_PASSWORD_MISMATCH') . ' ';
		}else {
			if(Crypt::Tea::decrypt($prefs->get('password'),$KEY) ne $params->{'pref_password'}) {
				$prefs->set('password',Crypt::Tea::encrypt($params->{'pref_password'},$KEY));
			}
		}
	}
	if ($params->{'saveSettings'}) {
		if($params->{'pref_squeezePlayPlayersEnabled'} && !$prefs->get('squeezePlayPlayersEnabled')) {
			$log->info('Enabling Squeezebox Touch/Radio players');
			$params->{'enabledSqueezePlayPlayers'} = 1;
		}elsif(!$params->{'pref_squeezePlayPlayersEnabled'} && $prefs->get('squeezePlayPlayersEnabled')) {
			$log->info('Disabling Squeezebox Touch/Radio players');
			$params->{'disabledSqueezePlayPlayers'} = 1;
		}	
	}
	
	if ($params->{'logout'}) {
		my @players = Slim::Player::Client::clients();
		foreach my $player (@players) {
			Plugins::IckStreamPlugin::PlayerManager::uninitializePlayer($player);
		}
		$prefs->set('accessToken',undef);
	}
	
	if($prefs->get('accessToken')) {
		my $cloudCoreUrl = $prefs->get('cloudCoreUrl') || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
		my $manageAccountUrl = $cloudCoreUrl;
		$manageAccountUrl =~ s/^(https?:\/\/.*?)\/.*/\1/;
		$params->{'manageAccountUrl'} = $manageAccountUrl;
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $jsonResponse = from_json($http->content);
				if(defined($jsonResponse->{'result'})) {
					$params->{'authenticationName'} = $jsonResponse->{'result'}->{'name'};
					my $result = finalizeHandler($class, $client, $params, $callback, $httpClient, $response);
					&{$callback}($client,$params,$result,$httpClient,$response);
				}else {
					my $result = finalizeHandler($class, $client, $params, $callback, $httpClient, $response);
					&{$callback}($client,$params,$result,$httpClient,$response);
				}
			},
			sub {
				my $result = finalizeHandler($class, $client, $params, $callback, $httpClient, $response);
				&{$callback}($client,$params,$result,$httpClient,$response);
			},
			undef
		)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$prefs->get('accessToken'),to_json({
			'jsonrpc' => '2.0',
			'id' => 1,
			'method' => 'getUser',
			'params' => {
			}
		}));
		return undef;
	}else {
		return finalizeHandler($class, $client, $params, $callback, $httpClient, $response);
	}
}

sub finalizeHandler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;
	
	my @players = Slim::Player::Client::clients();
	my @initializedPlayers = ();
	foreach my $player (@players) {
		if(Plugins::IckStreamPlugin::PlayerManager::isPlayerInitialized($player)) {
			push @initializedPlayers, $player;
		}
	}
	if(scalar(@initializedPlayers)>0) {
		$params->{'initializedPlayers'} = \@initializedPlayers;
	}
	
	my $result = $class->SUPER::handler($client, $params);
	if($params->{'enabledSqueezePlayPlayers'}) {
		my @players = Slim::Player::Client::clients();
		foreach my $player (@players) {
			if($player->modelName() eq 'Squeezebox Touch' || $player->modelName() eq 'Squeezebox Radio') {
				Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player);
			}
		}
	}elsif($params->{'disabledSqueezePlayPlayers'}) {
		my @players = Slim::Player::Client::clients();
		foreach my $player (@players) {
			if($player->modelName() eq 'Squeezebox Touch' || $player->modelName() eq 'Squeezebox Radio') {
				Plugins::IckStreamPlugin::PlayerManager::uninitializePlayer($player);
			}
		}
	}
	return $result;
}

sub handleAuthenticationFinished {
    my ($client, $params, $callback, $httpClient, $response) = @_;

	if(defined($params->{'code'})) {
	    my $serverIP = Slim::Utils::IPDetect::IP();
	    my $port = $serverPrefs->get('httpport');
	    my $serverUrl = "http://".$serverIP.":".$port."/plugins/IckStreamPlugin/settings/authenticationCallback.html";

		my $cloudCoreUrl = $prefs->get('cloudCoreUrl') || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
		my $cloudCoreToken = $cloudCoreUrl;
		$cloudCoreToken =~ s/^(https?:\/\/.*?)\/.*/\1/;

		my $httpParams = { timeout => 35 };
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $jsonResponse = from_json($http->content);
				if(defined($jsonResponse->{'access_token'})) {
					$log->info("Successfully authenticated user");
					
					$log->info("Register LMS as controller device");
					my $uuid = $prefs->get('controller_uuid');
					if(!defined($uuid)) {
						$uuid = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
						$prefs->set('controller_uuid',$uuid);
					}
					my $serverName = $serverPrefs->get('libraryname');
					if(!defined($serverName) || $serverName eq '') {
					                $serverName = Slim::Utils::Network::hostName();
			        }
					Slim::Networking::SimpleAsyncHTTP->new(
								sub {
									my $http = shift;
									my $jsonResponse = from_json($http->content);
									if(defined($jsonResponse->{'result'})) {
										Slim::Networking::SimpleAsyncHTTP->new(
											sub {
												my $http = shift;
												my $jsonResponse = from_json($http->content);
												if(defined($jsonResponse->{'result'})) {
													$log->info("LMS device registered successfully, storing access token");
													my $controllerAccessToken = $jsonResponse->{'result'}->{'accessToken'};
													$prefs->set('accessToken',$controllerAccessToken);
													my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationSuccess.html', $params);
													my @players = Slim::Player::Client::clients();
													foreach my $player (@players) {
														if($prefs->get('squeezePlayPlayersEnabled') || ($player->modelName() ne 'Squeezebox Touch' && $player->modelName() ne 'Squeezebox Radio')) {
															$log->debug("Processing player: ".$player->name());
															Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player);
														}
													}
													Plugins::IckStreamPlugin::BrowseManager::init();
													&{$callback}($client,$params,$output,$httpClient,$response);
												}else {
													$log->warn("Failed to register device in cloud: ".Dumper($jsonResponse));
													my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
													&{$callback}($client,$params,$output,$httpClient,$response);
												}
											},
											sub {
													$log->warn("Failed to register device in cloud");
													my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
													&{$callback}($client,$params,$output,$httpClient,$response);
											},
											undef
										)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$jsonResponse->{'result'},to_json({
											'jsonrpc' => '2.0',
											'id' => 1,
											'method' => 'addDevice',
											'params' => {
												'address' => $serverIP,
												'hardwareId' => $serverPrefs->get('server_uuid'),
												'applicationId' => 'C5589EF9-9C28-4556-942A-765E698215F1'
											}
										}));
									}else {
										$log->warn("Failed to get device registration token from cloud: ".Dumper($jsonResponse));
										my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
										&{$callback}($client,$params,$output,$httpClient,$response);
									}
								},
								sub {
									$log->warn("Failed to get device registration token from cloud");
									my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
									&{$callback}($client,$params,$output,$httpClient,$response);
								},
								undef
							)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$jsonResponse->{'access_token'},to_json({
								'jsonrpc' => '2.0',
								'id' => 1,
								'method' => 'createDeviceRegistrationToken',
								'params' => {
									'id' => $uuid,
									'name' => $serverName,
									'applicationId' => 'C5589EF9-9C28-4556-942A-765E698215F1'
								}
							}));
				}else {
					if(defined($jsonResponse->{'error_description'})) {
						$log->warn("Failed to authenticate: ".$jsonResponse->{'error'}.": ".$jsonResponse->{'error_description'});
					}else {
						$log->warn("Failed to authenticate: ".$jsonResponse->{'error'});
					}
					my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
					&{$callback}($client,$params,$output,$httpClient,$response);
				}
			},
			sub {
				my $http = shift;
				my $jsonResponse = from_json($http->content);
				if(defined($jsonResponse->{'error_description'})) {
					$log->warn("Failed to authenticate: ".$jsonResponse->{'error'}.": ".$jsonResponse->{'error_description'});
				}else {
					$log->warn("Failed to authenticate: ".$jsonResponse->{'error'});
				}
				my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
				&{$callback}($client,$params,$output,$httpClient,$response);
			},
			$params
		)->get($cloudCoreToken."/ickstream-cloud-core/oauth/token?redirect_uri=".$serverUrl."&code=".$params->{'code'},'Content-Type' => 'application/json');
	}
	return undef;
}

1;

__END__

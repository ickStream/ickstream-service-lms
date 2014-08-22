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
my $peerVerification = undef;

my $KEY = undef;

sub new {
        my $class = shift;
        my $plugin = shift;

		$KEY = Slim::Utils::PluginManager->dataForPlugin($plugin)->{'id'};
        $class->SUPER::new();
       	eval "use IO::Socket::SSL";
       	if(!$@ && IO::Socket::SSL->can("set_client_defaults")) {
       		$peerVerification = 1;
        	$log->debug("IO::Socket::SSL installed, activating possibility to disable SSL peer verification");
	        if($prefs->get('disablePeerVerification')) {
	        	$log->debug("Disabling SSL peer verification\n");
		        IO::Socket::SSL::set_client_defaults(          
					'SSL_verify_mode' => 0x0
				);
        	}
        }else {
        	$log->debug("Recent version of IO::Socket::SSL not installed, skipping possibility to disable SSL peer verification");
        }
        my @handlers = Slim::Player::ProtocolHandlers->registeredHandlers();
        if(!grep( /^https$/, @handlers )) {
        	$log->debug("Registering https handler");
        	Slim::Player::ProtocolHandlers->registerHandler("https",qw(Slim::Player::Protocols::HTTP));
        }
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('ICKSTREAM');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/IckStreamPlugin/settings/basic.html');
}

sub prefs {
	return ($prefs, 'orderAlbumsForArtist', 'daemonPort', 'squeezePlayPlayersEnabled', 'disablePeerVerification');
}

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	if ($serverPrefs->get('authorize')) {
		$params->{'authorize'} = 1
	}
	if($peerVerification) {
		$params->{'peerVerification'} = 1;
	}

	if ($params->{'saveSettings'} && $params->{'pref_password'}) {
		$log->debug("Verifying password");
		my $val = $params->{'pref_password'};
		if ($val ne $params->{'pref_password_repeat'}) {
			$params->{'warning'} .= Slim::Utils::Strings::string('SETUP_PASSWORD_MISMATCH') . ' ';
		}else {
			if(Crypt::Tea::decrypt($prefs->get('password'),$KEY) ne $params->{'pref_password'}) {
				$log->debug("Saving password");
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
	if ($params->{'saveSettings'} && $peerVerification) {
		savePeerVerificationSetting($params);
	}
	
	if ($params->{'logout'}) {
		logout();
	}

	saveConfirmedLicenses($params);	
	
	getUnconfirmedLicenses(
		sub {
			getApplicationIdForLMS(
				sub {
					getUserInformation(
						sub {
							if(!main::ISWINDOWS) {
								$params->{'daemonSupported'} = 1;
							}
							getInitializedPlayers($params);
							getRegisteredPlayers($params);
							enableDisableSqueezePlayPlayers($params);
							my $result = $class->SUPER::handler($client, $params);
							&{$callback}($client,$params,$result,$httpClient,$response);
						},
						$params
					)
				},
				$params
			);
		},
		$params
	);
			
	return undef;
}

sub _getCloudCoreUrl {
	return $prefs->get('cloudCoreUrl') || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
}

sub _getManageAccountUrl {
	my $manageAccountUrl = _getCloudCoreUrl();
	$manageAccountUrl =~ s/^(https?:\/\/.*?)\/.*/\1/;
	$manageAccountUrl =~ s/^(https?:\/\/)api(.*)/\1cloud\2/;
	return $manageAccountUrl;
}

sub _getRedirectUrl {
    my $serverIP = Slim::Utils::IPDetect::IP();
    my $port = $serverPrefs->get('httpport');
	my $serverUrl = "http://".$serverIP.":".$port."/plugins/IckStreamPlugin/settings/authenticationCallback.html";
    return $serverUrl;
}

sub savePeerVerificationSetting {
	my $params = shift;
	
	eval "use IO::Socket::SSL";
	if($params->{'pref_disablePeerVerification'}) {
       	$log->debug("Disabling SSL peer verification\n");
        IO::Socket::SSL::set_client_defaults(          
			'SSL_verify_mode' => 0x0   
		);
	}else {
       	$log->debug("Enabling SSL peer verification\n");
        IO::Socket::SSL::set_client_defaults(          
			'SSL_verify_mode' => 0x1   
		);
	}
}

sub logout {
	$log->debug("Uninitializing players");
	my @players = Slim::Player::Client::clients();
	foreach my $player (@players) {
		$log->debug("Uninitializing player ".$player->name());
		Plugins::IckStreamPlugin::PlayerManager::uninitializePlayer($player);
	}
	$prefs->set('accessToken',undef);
}

sub saveConfirmedLicenses {
	my $params = shift;

	foreach my $param (keys %$params) {
		if($param =~ /^confirmed_license_(.*)$/) {
			$log->debug("Registering license confirmation for :". $params->{$param});
			my $playerModel = $1;
			my $confirmedLicenseMD5 = $params->{$param};
			my @players = Slim::Player::Client::clients();
			if($playerModel eq 'lms') {
				Plugins::IckStreamPlugin::LicenseManager::confirmLicense(undef,$confirmedLicenseMD5);
			}else {
				foreach my $player (@players) {
					if($player->model() eq $playerModel) {
						Plugins::IckStreamPlugin::LicenseManager::confirmLicense($player,$confirmedLicenseMD5);
					}
				}
			}
			foreach my $player (@players) {
				Plugins::IckStreamPlugin::LicenseManager::addLicenseIfConfirmed($player,$confirmedLicenseMD5); 
			}
			Plugins::IckStreamPlugin::LicenseManager::addLicenseIfConfirmed(undef,$confirmedLicenseMD5); 
		}
	}
}

sub getApplicationIdForLMS {
	my $callback = shift;
	my $params = shift;
	
	if(!Plugins::IckStreamPlugin::LicenseManager::isLicenseConfirmed()) {
		&{$callback}();
	}
	Plugins::IckStreamPlugin::LicenseManager::getApplicationId(undef,
		sub {
			my $application = shift;
			
			my $authenticationUrl = _getCloudCoreUrl();
			$authenticationUrl =~ s/^(https?:\/\/.*?)\/.*/\1/;
			$params->{'authenticationUrl'} = $authenticationUrl.'/ickstream-cloud-core/oauth?redirect_uri='._getRedirectUrl().'&client_id='.$application;
			
			&{$callback}();
		},
		sub {
			my $error = shift;

			&{$callback}();
		});
}

sub getUnconfirmedLicenses {
	my $callback = shift;
	my $params = shift;
	my $remainingPlayers = shift;
	
	if(!defined($remainingPlayers)) {
		my @players = Slim::Player::Client::clients();
		unshift @players, undef;
		$remainingPlayers = \@players;
	}
	
	if(scalar(@$remainingPlayers)>0) {
		my $player = shift @$remainingPlayers;
		if(!Plugins::IckStreamPlugin::LicenseManager::isLicenseConfirmed($player)) {
			if($player) {
				$log->debug("Getting license for ".$player->name());
			}else {
				$log->debug("Getting license for Logitech Media Server");
			}
			Plugins::IckStreamPlugin::LicenseManager::getLicense($player,
				sub {
					my $md5 = shift;

					if(!defined($params->{'unconfirmedLicenses'})) {
						$params->{'unconfirmedLicenses'} = {};
					}
					my $unconfirmedLicenses = $params->{'unconfirmedLicenses'};
					if(!defined($unconfirmedLicenses->{$md5})) {
						$unconfirmedLicenses->{$md5} = {};
					}
					if($player) {
						my $model = $player->model();
						if(!defined($unconfirmedLicenses->{$md5}->{$model})) {
							$unconfirmedLicenses->{$md5}->{$model} = $player->modelName();
						}
					}else {
						if(!defined($unconfirmedLicenses->{$md5}->{"lms"})) {
							$unconfirmedLicenses->{$md5}->{"lms"} = "Logitech Media Server";
						}
					}
					
					getUnconfirmedLicenses($callback, $params, $remainingPlayers);
				},
				sub {
					if($player) {
						if(!defined($params->{'unsupportedPlayers'})) {
							my @empty = ();
							$params->{'unsupportedPlayers'} = \@empty;
						}
						my $unsupportedPlayers = $params->{'unsupportedPlayers'};
						push @$unsupportedPlayers, $player;
					}

					getUnconfirmedLicenses($callback, $params, $remainingPlayers);
				});
		}else {
			getUnconfirmedLicenses($callback,$params, $remainingPlayers);
		}
	}else {
		&{$callback}();
	}
	
}
	
sub getUserInformation {
	my ($callback, $params) = @_;
	
	Plugins::IckStreamPlugin::LicenseManager::getApplicationId(undef,
		sub {
			my $applicationId = shift;
			if($prefs->get('accessToken')) {
				$params->{'manageAccountUrl'} = _getManageAccountUrl();
				$log->debug("Retrieving information about user account");
				my $httpParams = { timeout => 35 };
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						if(defined($jsonResponse->{'result'})) {
							$log->debug("Logged in user is: ".$jsonResponse->{'result'}->{'name'});
							$params->{'authenticationName'} = $jsonResponse->{'result'}->{'name'};
							&{$callback}();
						}else {
							$log->warn("Unable to get logged in user");
							&{$callback}();
						}
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Error when getting logged in user: $error");
						&{$callback}();
					},
					$httpParams
				)->post(_getCloudCoreUrl(),'Content-Type' => 'application/json','Authorization'=>'Bearer '.$prefs->get('accessToken'),to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'getUser',
					'params' => {
					}
				}));
				return undef;
			}else {
				$log->debug("Not logged in");
				&{$callback}();
			}
		},
		sub {
			my $error = shift;
			$log->warn("Failed to get application identity: ".$error);
			&{$callback}();
		})
}

sub getInitializedPlayers {
	my $params = shift;

	my @initializedPlayers = ();

	my @players = Slim::Player::Client::clients();

	foreach my $player (@players) {
		$log->debug("Check if ".$player->name()." is initialized already");
		if(Plugins::IckStreamPlugin::PlayerManager::isPlayerInitialized($player)) {
			$log->debug($player->name()." is initialized already");
			push @initializedPlayers, $player;
		}
	}
	if(scalar(@initializedPlayers)>0) {
		$params->{'initializedPlayers'} = \@initializedPlayers;
	}
}

sub getRegisteredPlayers {
	my $params = shift;

	my @registeredPlayers = ();

	my @players = Slim::Player::Client::clients();
	foreach my $player (@players) {
		if(Plugins::IckStreamPlugin::PlayerManager::isPlayerRegistered($player)) {
			push @registeredPlayers, $player;
		}else {
			$log->debug($player->name()." is not yet registered");
		}
	}

	if(scalar(@registeredPlayers)>0) {
		$params->{'registeredPlayers'} = \@registeredPlayers;
	}
}

sub enableDisableSqueezePlayPlayers {
	my $params = shift;
	
	if($params->{'enabledSqueezePlayPlayers'}) {
		my @players = Slim::Player::Client::clients();
		$log->debug("Found ".scalar(@players)." players");
		foreach my $player (@players) {
			if(Plugins::IckStreamPlugin::LicenseManager::isLicenseConfirmed($player)) {
				if($player->modelName() eq 'Squeezebox Touch' || $player->modelName() eq 'Squeezebox Radio') {
					$log->debug("Trying to initialize ".$player->name());
					Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player);
				}
			}
		}
	}elsif($params->{'disabledSqueezePlayPlayers'}) {
		my @players = Slim::Player::Client::clients();
		$log->debug("Found ".scalar(@players)." players");
		foreach my $player (@players) {
			if($player->modelName() eq 'Squeezebox Touch' || $player->modelName() eq 'Squeezebox Radio') {
				$log->debug("Uninitializing ".$player->name());
				Plugins::IckStreamPlugin::PlayerManager::uninitializePlayer($player);
			}
		}
	}elsif($params->{'register_players'}) {
		my @players = Slim::Player::Client::clients();
		$log->debug("Found ".scalar(@players)." players");
		foreach my $player (@players) {
			if(Plugins::IckStreamPlugin::LicenseManager::isLicenseConfirmed($player)) {
				if($prefs->get('squeezePlayPlayersEnabled') || ($player->modelName() ne 'Squeezebox Touch' && $player->modelName() ne 'Squeezebox Radio')) {
					if(!Plugins::IckStreamPlugin::PlayerManager::isPlayerInitialized($player)) {
						$log->debug("Trying to initialize ".$player->name());
						Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player);
					}elsif(!Plugins::IckStreamPlugin::PlayerManager::isPlayerRegistered($player)) {
						$log->debug("Trying to register ".$player->name());
						Plugins::IckStreamPlugin::PlayerManager::updateAddressOrRegisterPlayer($player);
					}else {
						$log->debug($player->name()." is already initialized and registered");
					}
				}
			}
		}
	}
}

sub handleAuthenticationFinished {
    my ($client, $params, $callback, $httpClient, $response) = @_;

	if(defined($params->{'code'})) {
		$log->debug("Authorization code successfully retrieved");

		my $cloudCoreToken = _getCloudCoreUrl();
		$cloudCoreToken =~ s/^(https?:\/\/.*?)\/.*/\1/;

	    my $serverIP = Slim::Utils::IPDetect::IP();

		my $httpParams = { timeout => 35 };
		$log->debug("Retrieving token from ".$cloudCoreToken);
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $jsonResponse = from_json($http->content);
				if(defined($jsonResponse->{'access_token'})) {
					$log->info("Successfully authenticated user");
					
					$log->info("Generate UUID for controller device");
					my $uuid = $prefs->get('controller_uuid');
					if(!defined($uuid)) {
						$uuid = uc(UUID::Tiny::create_UUID_as_string( UUID::Tiny::UUID_V4() ));
						$prefs->set('controller_uuid',$uuid);
					}
					
					$prefs->set('accessToken',$jsonResponse->{'access_token'});
					$params->{'manageAccountUrl'} = _getManageAccountUrl();
					my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationSuccess.html', $params);
					my @players = Slim::Player::Client::clients();
					foreach my $player (@players) {
						if(Plugins::IckStreamPlugin::LicenseManager::isLicenseConfirmed($player)) {
							if($prefs->get('squeezePlayPlayersEnabled') || ($player->modelName() ne 'Squeezebox Touch' && $player->modelName() ne 'Squeezebox Radio')) {
								$log->debug("Initializing player: ".$player->name());
								Plugins::IckStreamPlugin::PlayerManager::initializePlayer($player, sub {
										$log->debug("Initialization finished for: ".$player->name());
									});
							}
						}
					}
					&{$callback}($client,$params,$output,$httpClient,$response);
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
				my $error = shift;
				$log->warn("Authentication error when calling: ".$cloudCoreToken."/ickstream-cloud-core/oauth/token?redirect_uri="._getRedirectUrl()."&code=".$params->{'code'}.": ".$error);
				my $output = Slim::Web::HTTP::filltemplatefile('plugins/IckStreamPlugin/settings/authenticationError.html', $params);
				&{$callback}($client,$params,$output,$httpClient,$response);
			},
			$httpParams
		)->get($cloudCoreToken."/ickstream-cloud-core/oauth/token?redirect_uri="._getRedirectUrl()."&code=".$params->{'code'},'Content-Type' => 'application/json');
	}
	return undef;
}

1;

__END__

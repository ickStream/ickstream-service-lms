# Copyright (c) 2014, ickStream GmbH
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

# Handler for localickstream:// URLs
package Plugins::IckStreamPlugin::LocalProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::File);
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Plugins::IckStreamPlugin::ItemCache;
use Plugins::IckStreamPlugin::Plugin;


my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.protocol',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_PROTOCOL_LOG',
});
my $prefs = preferences('plugin.ickstream');

sub new {
	my $class  = shift;
	my $args   = shift;
	main::DEBUGLOG && $log->debug("new(".$class.",".$args.")");
	
	my $sock = $class->SUPER::new( {
		song    => $args->{song},
		client  => $args->{client},
	} ) || return;

	return $sock;
}

sub _findTrackId {
	my $ickStreamId = shift;
	
	my $trackId = undef;
	if($ickStreamId =~ /^ickstreamlocal:\/\/([^\/]*):lms:track:(.*)$/) {
		my $serviceId = $1;
		my $ickStreamTrackId = $2;
		if($serviceId eq $prefs->get('uuid')) {
			my $sql = "SELECT id from TRACKS where urlmd5=?";
			my $dbh = Slim::Schema->dbh;
			my $sth = $dbh->prepare_cached($sql);
			my @params = ($ickStreamTrackId);
			$sth->execute(@params);
			$sth->bind_col(1,\$trackId);
			if ($sth->fetch) {
				# Do nothing, fetch will put the info in right place already
			}
			$sth->finish();
		}
	}
	if($trackId) {
		$log->warn("Found track: $trackId");
	}else {
		$log->warn("Unkonwn track with url: ".$ickStreamId);
	}
	return $trackId;
}

sub formatOverride {
	my $self = shift;
	my $song = shift;
	
	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache($song->track->url());
	if(!defined($meta) || !defined($song->currentTrack()) || $song->currentTrack()->url !~ /^file:/) {
		my $trackId = _findTrackId($song->track->url());
		if(defined($trackId)) {
			$song->_currentTrack(Slim::Schema->resultset('Track')->find($trackId));
		}
		my $format = Slim::Music::Info::contentType($song->currentTrack());
		Plugins::IckStreamPlugin::ItemCache::setItemInCache($song->track->url(),{
			'format' => $format
		});					        
		return $format;
	}else {
		return $meta->{'format'};
	}
}

# Metadata for a URL, used by CLI/JSON clients
sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	#main::DEBUGLOG && $log->debug("getMetadataFor(".$class.",".$client.",".$url.")");
        
	my $icon = $class->getIcon();
        
	return {} unless $url;
         
	# If metadata is not here, fetch it so the next poll will include the data
	my ($trackId,$serviceId) = _getStreamParams( $url );
	my $meta = Plugins::IckStreamPlugin::ItemCache::getItemFromCache($trackId);

	if ( $meta ) {

		if(defined($meta->{'cover'}) && $meta->{'cover'} =~ /^service:\/\//) {
			$meta->{'cover'} = Plugins::IckStreamPlugin::LocalServiceManager::resolveServiceUrl($serviceId,$meta->{'cover'});	
		}
	}
	
	return $meta || {
		icon      => $icon,
		cover     => $icon,
	};
}

sub getIcon {
	my ( $class, $url ) = @_;
	#main::DEBUGLOG && $log->debug("getIcon(".$class.",".$url.")");

	return Plugins::IckStreamPlugin::Plugin->_pluginDataFor('icon');
}


sub _getStreamParams {
        $_[0] =~ m{ickstreamlocal://(.+)}i;
        my $trackId = $1;
        $trackId =~ m{(.+?):.+}i;
        return ($trackId,$1);
}

1;

__END__

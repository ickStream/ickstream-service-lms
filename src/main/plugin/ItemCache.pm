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

package Plugins::IckStreamPlugin::ItemCache;

use strict;
use Scalar::Util qw(blessed);
use Plugins::IckStreamPlugin::Plugin;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;

my $log   = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');

sub getItemFromCache {
	my $itemId = shift;
	
	my $cache = Slim::Utils::Cache->new("IckStreamItemCache");
	my $meta = $cache->get( $itemId );
	return $meta;
}

sub setItemInCache {
	my $itemId = shift;
	my $item = shift;
	my $streamingRef = shift;

	my $icon = Plugins::IckStreamPlugin::Plugin->_pluginDataFor('icon');
	my $meta = {
		artist    => $item->{itemAttributes}->{mainArtists}->[0]->{name},
		album     => $item->{itemAttributes}->{album}->{name},
		title     => $item->{text},
		cover     => $item->{image} || $icon,
		duration  => $item->{itemAttributes}->{duration},
		icon      => $icon,
	};
	if(defined($item->{'streamingRefs'}) && $item->{'streamingRefs'}->[0]-{'url'}) {
		$meta->{'url'} = $item->{'streamingRefs'}->[0]->{'url'};
		if(defined($item->{'streamingRefs'}->[0]->{'format'})) {
			$meta->{'format'} = $item->{'streamingRefs'}->[0]->{'format'}
		}
	}elsif(defined($streamingRef) && defined($streamingRef->{'format'})) {
		$meta->{'format'} = $streamingRef->{'format'}
	}

	my $cache = Slim::Utils::Cache->new("IckStreamItemCache");
	$cache->set($itemId,$meta, 86400 );
	return $meta;
}

sub setItemStreamingRefInCache {
	my $itemId = shift;
	my $meta = shift;
	my $streamingRef = shift;
	
	my $cache = Slim::Utils::Cache->new("IckStreamItemCache");
	my $meta = $cache->get($itemId);
	if(defined($streamingRef) && defined($streamingRef->{'format'})) {
		$meta->{'format'} = $streamingRef->{'format'}
	}
	$cache->set($itemId,$meta, 86400 );
	return $meta;
}


1;

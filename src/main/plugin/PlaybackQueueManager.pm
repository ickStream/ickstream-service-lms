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

package Plugins::IckStreamPlugin::PlaybackQueueManager;

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Plugins::IckStreamPlugin::ItemCache;

my $log   = logger('plugin.ickstream.player');
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $playbackQueuesLastChanged = {};
my $originalPlaybackQueues = {};
my $playbackQueues = {};

sub getLastChanged {
	my $player = shift;
	
	if(defined($playbackQueuesLastChanged->{$player->id})) {
		return $playbackQueuesLastChanged->{$player->id};
	}else {
		return undef;
	}
}

sub getPlaybackQueue {
	my $player = shift;
	
	my $playbackQueue = $playbackQueues->{$player->id};
	my @emptyPlaybackQueue = ();
	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));
	
	return $playbackQueue;
}

sub getOriginalPlaybackQueue {
	my $player = shift;
	
	my $playbackQueue = $originalPlaybackQueues->{$player->id};
	my @emptyPlaybackQueue = ();
	$playbackQueue = \@emptyPlaybackQueue if(!defined($playbackQueue));
	
	return $playbackQueue;
}

sub setPlaybackQueue {
	my $player = shift;
	my $playbackQueue = shift;
	
	$playbackQueues->{$player->id} = $playbackQueue;
	
	my $timestamp = int(Time::HiRes::time() * 1000);
	$playbackQueuesLastChanged->{$player->id} = $timestamp;

}

sub setOriginalPlaybackQueue {
	my $player = shift;
	my $playbackQueue = shift;
	
	$originalPlaybackQueues->{$player->id} = $playbackQueue;
	
	my $timestamp = int(Time::HiRes::time() * 1000);
	$playbackQueuesLastChanged->{$player->id} = $timestamp;

}

1;

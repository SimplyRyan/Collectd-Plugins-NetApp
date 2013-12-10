# --
# NetApp/Aggr.pm - Collectd Perl Plugin for NetApp Storage Systems (Aggr Module)
# https://github.com/aleex42/Collectd-Plugins-NetApp
# Copyright (C) 2013 Alexander Krogloth, E-Mail: git <at> krogloth.de
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (GPL). If you
# did not receive this file, see http://www.gnu.org/licenses/gpl.txt.
# --

package Collectd::Plugins::NetApp::Aggr;

use base 'Exporter';
our @EXPORT = qw(aggr_module);

use strict;
use warnings;

use feature qw(switch);

use Collectd qw( :all );
use Collectd::Plugins::NetApp::NACommon qw(connect_filer);

use lib "/usr/lib/netapp-manageability-sdk-5.1/lib/perl/NetApp";
use NaServer;
use NaElement;

use Config::Simple;

sub cdot_df {

    my $hostname = shift;
    my %df_return;

    my $api = new NaElement('volume-get-iter');
    my $xi = new NaElement('desired-attributes');
    $api->child_add($xi);
    my $xi1 = new NaElement('volume-attributes');
    $xi->child_add($xi1);
    my $xi2 = new NaElement('volume-space-attributes');
    $xi1->child_add($xi2);
    $xi2->child_add_string('size-available','<size-available>');
    $xi2->child_add_string('size-used','<size-used>');
    my $xi3 = new NaElement('volume-state-attributes');
    $xi1->child_add($xi3);
    $xi3->child_add_string('state','<state>');
    my $xi4 = new NaElement('volume-id-attributes');
    $xi4->child_add_string('name','name');
    $api->child_add_string('max-records','1000');

    my $output = connect_filer($hostname)->invoke_elem($api);

    my $volumes = $output->child_get("attributes-list");
    my @result = $volumes->children_get();

    if($output){

        foreach my $vol (@result){

            my $vol_state_attributes = $vol->child_get("volume-state-attributes");

            if($vol->child_get("volume-state-attributes")){

                my $vol_info = $vol->child_get("volume-id-attributes");
                my $vol_name = $vol_info->child_get_string("name");

                if($vol_state_attributes->child_get_string("state") eq "online"){

                    my $vol_space = $vol->child_get("volume-space-attributes");

                    my $used = $vol_space->child_get_string("size-used");
                    my $free = $vol_space->child_get_int("size-available");

                    $df_return{$vol_name} = [ $used, $free ];
                }
            }
        }

        return \%df_return;

    } else {

        return undef;

    }
}

sub smode_df {

    my $hostname = shift;
    my %df_return;

    my $out = connect_filer($hostname)->invoke("volume-list-info");

    my $instances_list = $out->child_get("volumes");
    my @instances = $instances_list->children_get();

    foreach my $volume (@instances){

        my $vol_name = $volume->child_get_string("name");

        my $snap = NaElement->new("snapshot-list-info");
        $snap->child_add_string("volume",$vol_name);
        my $snap_out = connect_filer($hostname)->invoke_elem($snap);

        my $snap_instances_list = $snap_out->child_get("snapshots");

        if($snap_instances_list){

            my @snap_instances = $snap_instances_list->children_get();

            my $cumulative = 0;

            foreach my $snap (@snap_instances){
                if($snap->child_get_int("cumulative-total") > $cumulative){
                    $cumulative = $snap->child_get_int("cumulative-total");
                }
            }

            my $snap_used = $cumulative*1024;
            my $vol_free = $volume->child_get_int("size-available");
            my $vol_used = $volume->child_get_int("size-used");

            my $snap_reserved = $volume->child_get_int("snapshot-blocks-reserved") * 1024;
            my $snap_norm_used;
            my $snap_reserve_free;
            my $snap_reserve_used;        

            if($snap_reserved > $snap_used){
                $snap_reserve_free = $snap_reserved - $snap_used;
                $snap_reserve_used = $snap_used;
                $snap_norm_used = 0;
            } else {
                $snap_reserve_free = 0;
                $snap_reserve_used = $snap_reserved;
                $snap_norm_used = $snap_used - $snap_reserved;
            }

            if ( $vol_used >= $snap_norm_used){
                $vol_used = $vol_used - $snap_norm_used;
            } 

            $df_return{$vol_name} = [ $vol_free, $vol_used, $snap_reserve_free, $snap_reserve_used, $snap_norm_used];

        }           
    }

    return \%df_return;
}

sub smode_aggr_df {

    my $hostname = shift;
    my (%df_return, $used_space, $total_space, $total_transfers);

    my $in = NaElement->new("perf-object-get-instances");
    $in->child_add_string("objectname","aggregate");
    my $counters = NaElement->new("counters");
    $counters->child_add_string("counter","wv_fsinfo_blks_total");
    $counters->child_add_string("counter","wv_fsinfo_blks_used");
    $counters->child_add_string("counter","wv_fsinfo_blks_reserve");
    $counters->child_add_string("counter","wv_fsinfo_blks_snap_reserve_pct");
    $counters->child_add_string("counter","total_transfers");
    $in->child_add($counters);
    my $out = connect_filer($hostname)->invoke_elem($in);

    my $instances_list = $out->child_get("instances");
    if($instances_list){

        my @instances = $instances_list->children_get();

        foreach my $aggr (@instances){

            my $aggr_name = $aggr->child_get_string("name");

            my $counters_list = $aggr->child_get("counters");
            my @counters =  $counters_list->children_get();

            my %values = (wv_fsinfo_blks_total => undef, wv_fsinfo_blks_used => undef, wv_fsinfo_blks_reserve => undef, wv_fsinfo_blks_snap_reserve_pct => undef, total_transfers => undef);

            foreach my $counter (@counters){

                my $key = $counter->child_get_string("name");
                if(exists $values{$key}){
                    $values{$key} = $counter->child_get_string("value");
                }
            }

            my $used_space = $values{wv_fsinfo_blks_used} * 4096;
            my $usable_space = ($values{wv_fsinfo_blks_total} - $values{wv_fsinfo_blks_reserve} - $values{wv_fsinfo_blks_snap_reserve_pct} * $values{wv_fsinfo_blks_total} / 100)*4096;
            my $free_space = $usable_space - $used_space;

            $df_return{$aggr_name} = [ $used_space, $free_space, $values{total_transfers} ];
        }

        return \%df_return;

    } else {
        return undef;
    }
}

sub cdot_aggr_df {

    my $hostname = shift;
    my %df_return;

    my $output = connect_filer($hostname)->invoke("aggr-get-iter");

    my $aggrs = $output->child_get("attributes-list");

    if($aggrs){
    my @result = $aggrs->children_get();

    foreach my $aggr (@result){
            my $aggr_name = $aggr->child_get_string("aggregate-name");
            my $space = $aggr->child_get("aggr-space-attributes");

            my $free = $space->child_get_int("size-available");
            my $used = $space->child_get_int("size-used");

            $df_return{$aggr_name} = [ $used, $free ];
        }

        return \%df_return;
    } else { 
        return undef;
    }
}

sub aggr_module {

    my ($hostname, $filer_os) = @_;

    given ($filer_os){

        when("cDOT"){

            my $aggr_df_result = cdot_aggr_df($hostname);
        
            if($aggr_df_result){

                foreach my $aggr (keys %$aggr_df_result){

                    my $aggr_value_ref = $aggr_df_result->{$aggr};
                    my @aggr_value = @{ $aggr_value_ref };

                    plugin_dispatch_values({
                            plugin => 'df_aggr',
                            plugin_instance => $aggr,
                            type => 'df_complex',
                            type_instance => 'used',
                            values => [$aggr_value[0]],
                            interval => '30',
                            host => $hostname,
                            });

                    plugin_dispatch_values({
                            plugin => 'df_aggr',
                            plugin_instance => $aggr,
                            type => 'df_complex',
                            type_instance => 'free',
                            values => [$aggr_value[1]],
                            interval => '30',
                            host => $hostname,
                            });
                }
            }
        }

        default {

            my $aggr_df_result = smode_aggr_df($hostname);

            if($aggr_df_result){

                foreach my $aggr (keys %$aggr_df_result){

                    my $aggr_value_ref = $aggr_df_result->{$aggr};
                    my @aggr_value = @{ $aggr_value_ref };

                    plugin_dispatch_values({
                            plugin => 'df_aggr',
                            plugin_instance => $aggr,
                            type => 'df_complex',
                            type_instance => 'used',
                            values => [$aggr_value[0]],
                            interval => '30',
                            host => $hostname,
                            });

                    plugin_dispatch_values({
                            plugin => 'df_aggr',
                            plugin_instance => $aggr,
                            type => 'df_complex',
                            type_instance => 'free',
                            values => [$aggr_value[1]],
                            interval => '30',
                            host => $hostname,
                            });

                    plugin_dispatch_values({
                            plugin => 'iops_aggr',
                            type => 'operations',
                            type_instance => $aggr,
                            values => [$aggr_value[2]],
                            interval => '30',
                            host => $hostname,
                            });
                }
            }
        }
    }

    return 1;
}

1;

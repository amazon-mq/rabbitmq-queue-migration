// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// vim:ft=javascript:
// -*- mode: javascript; -*-

dispatcher_add(function(sammy) {
    sammy.get('#/queue-compatibility', function() {
        render({},
               'queue-compatibility', '#/queue-compatibility');
    });

    sammy.get('#/queue-compatibility/:vhost', function() {
        var vhost = esc(this.params['vhost']);
        render({compatibility_results: '/queue-compatibility/check/' + vhost},
               'queue-compatibility-results', '#/queue-compatibility');
    });
});

NAVIGATION['Admin'][0]['Queue Compatibility'] = ['#/queue-compatibility', "monitoring"];

function fmt_check_type_name(checkType) {
    var nameMap = {
        'relaxed_checks_setting': 'Relaxed Checks Setting',
        'leader_balance': 'Queue Leader Balance',
        'queue_synchronization': 'Queue Synchronization',
        'queue_suitability': 'Queue Suitability',
        'message_count': 'Message Count Limits',
        'disk_space': 'Disk Space'
    };
    return nameMap[checkType] || checkType;
}

function fmt_compatibility_status(compatible) {
    if (compatible) {
        return '<span class="status-green">Compatible</span>';
    } else {
        return '<span class="status-red">Incompatible</span>';
    }
}

function fmt_compatibility_percentage(percentage) {
    var color;
    if (percentage >= 90) {
        color = '#008800'; // Green
    } else if (percentage >= 70) {
        color = '#ddaa00'; // Yellow
    } else {
        color = '#cc0000'; // Red
    }

    return '<div style="width: ' + percentage + '%; background-color: ' + color + '"> ' + percentage + '%</div>';
}

function fmt_issue_type(type) {
    var typeMap = {
        'exclusive': 'Exclusive Queue',
        'unsupported_argument': 'Unsupported Argument',
        'max_priority': 'Priority Queue',
        'lazy_mode': 'Lazy Mode',
        'overflow_behavior': 'Overflow Behavior',
        'incompatible_overflow': 'Incompatible Overflow',
        'message_count_limit': 'Too Many Messages',
        'data_size_limit': 'Too Much Data',
        'too_many_queues': 'Too Many Queues'
    };

    return typeMap[type] || type;
}

function fmt_queue_resource(resource) {
    if (!resource) return '';

    // Try to use link_queue if available, otherwise fallback to plain text
    try {
        if (typeof link_queue === 'function') {
            return link_queue(resource.vhost, resource.name);
        } else {
            // Fallback: just show the queue name as plain text
            return resource.name;
        }
    } catch (e) {
        // If link_queue fails, fallback to plain text
        return resource.name;
    }
}

function fmt_system_check_status(status) {
    return status === 'passed' ?
        '<span class="status-green">✓ Passed</span>' :
        '<span class="status-red">✗ Failed</span>';
}

function toggle_issue_details(queueName) {
    $('#issues-' + queueName).toggle();
}

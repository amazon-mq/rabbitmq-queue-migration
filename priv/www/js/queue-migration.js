// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0
// vim:ft=javascript:
// -*- mode: javascript; -*-

dispatcher_add(function(sammy) {
    sammy.get('#/queue-migration/status', function() {
        render({queue_migration_status: '/queue-migration/status', vhosts: '/vhosts'},
               'queue-migration-status', '#/queue-migration/status');
    });

    sammy.get('#/queue-migration/status/:migration_id', function() {
        render({queue_migration_detail_status: '/queue-migration/status/' + esc(this.params['migration_id'])},
               'queue-migration-detail-status', '#/queue-migration/status');
    });

    sammy.post('#/queue-migration/check', function() {
        var vhost = $('#migration-vhost').val() || '/';
        var requestBody = {};
        if ($('#skip_unsuitable_queues').is(':checked')) {
            requestBody.skip_unsuitable_queues = true;
        }

        with_req('POST', '/queue-migration/check/' + encodeURIComponent(vhost), JSON.stringify(requestBody), function(resp) {
            var data = JSON.parse(resp.responseText);
            var html = format('queue-migration-check-results', {compatibility_results: data});
            $('#compatibility-results').html(html);
        });

        return false;
    });

    sammy.put('#/queue-migration/start', function() {
        var self = this;

        // Build request body with options
        var requestBody = {};
        if (self.params.skip_unsuitable_queues === 'on') {
            requestBody.skip_unsuitable_queues = true;
        }

        // Use the existing with_req function for async requests with proper error handling
        with_req('POST', '/queue-migration/start/' + encodeURIComponent(self.params.vhost), JSON.stringify(requestBody), function(resp) {
            // Success callback - migration started successfully
            $('#start-migration-section').hide();
            $('#migration-started-message').show();
            // Give the backend time to create migration record before refreshing
            setTimeout(function() {
                update();
            }, 3000); // 3 second delay
        });

        return false;
    });
});

NAVIGATION['Admin'][0]['Queue Migration'] = ['#/queue-migration/status', "monitoring"];

// Preserve batch size form state across page refreshes
$(document).ready(function() {
    // Save state on any change
    $(document).on('change', 'input[name="batch_mode"], #batch_size, #migration-vhost, #skip_unsuitable_queues, #batch_order', function() {
        localStorage.setItem('rqm_batch_mode', $('input[name="batch_mode"]:checked').val() || 'limited');
        localStorage.setItem('rqm_batch_size', $('#batch_size').val() || '10');
        localStorage.setItem('rqm_vhost', $('#migration-vhost').val() || '/');
        localStorage.setItem('rqm_skip_unsuitable', $('#skip_unsuitable_queues').is(':checked'));
        localStorage.setItem('rqm_batch_order', $('#batch_order').val() || 'smallest_first');
    });

    // Restore state after any render (use MutationObserver to detect DOM changes)
    var observer = new MutationObserver(function() {
        if ($('#batch_limited').length > 0) {
            var savedMode = localStorage.getItem('rqm_batch_mode') || 'limited';
            var savedSize = localStorage.getItem('rqm_batch_size') || '10';
            var savedVhost = localStorage.getItem('rqm_vhost') || '/';
            var savedSkip = localStorage.getItem('rqm_skip_unsuitable') === 'true';
            var savedOrder = localStorage.getItem('rqm_batch_order') || 'smallest_first';

            if (savedMode === 'all') {
                $('#batch_all').prop('checked', true);
            } else {
                $('#batch_limited').prop('checked', true);
            }
            $('#batch_size').val(savedSize);
            $('#migration-vhost').val(savedVhost);
            $('#skip_unsuitable_queues').prop('checked', savedSkip);
            $('#batch_order').val(savedOrder);

            // Update input disabled state based on radio selection
            $('#batch_size').prop('disabled', $('#batch_all').is(':checked'));
        }
    });

    observer.observe(document.body, { childList: true, subtree: true });
});

// Enable/disable batch size input based on radio button selection
$(document).on('change', 'input[name="batch_mode"]', function() {
    $('#batch_size').prop('disabled', $('#batch_all').is(':checked'));
});

$(document).on('click', '#start-migration-btn', function() {
    var vhost = $('#migration-vhost').val() || '/';
    var requestBody = {};
    if ($('#skip_unsuitable_queues').is(':checked')) {
        requestBody.skip_unsuitable_queues = true;
    }
    if ($('#batch_limited').is(':checked')) {
        var batchSize = parseInt($('#batch_size').val(), 10);
        if (!isNaN(batchSize) && batchSize > 0) {
            requestBody.batch_size = batchSize;
        }
    }
    var batchOrder = $('#batch_order').val();
    if (batchOrder) {
        requestBody.batch_order = batchOrder;
    }

    with_req('POST', '/queue-migration/start/' + encodeURIComponent(vhost), JSON.stringify(requestBody), function(resp) {
        $('#migration-started-message').show();
        $('#migration-controls').hide();
        $('#migration-in-progress').show();
        setTimeout(function() {
            update();
        }, 3000);
    });
});

$(document).on('click', '.interrupt-migration-link', function(e) {
    e.preventDefault();
    var migrationId = $(this).data('migration-id');
    with_req('POST', '/queue-migration/interrupt/' + encodeURIComponent(migrationId), null, function(resp) {
        update();
    });
});

// Poll for migration status changes to toggle UI sections
setInterval(function() {
    if ($('#migration-in-progress').length === 0) return;

    with_req('GET', '/queue-migration/status', null, function(resp) {
        var data = JSON.parse(resp.responseText);
        var inProgress = data.status === 'in_progress';
        if (inProgress) {
            $('#migration-controls').hide();
            $('#migration-in-progress').show();
            update();
        } else {
            $('#migration-controls').show();
            $('#migration-in-progress').hide();
            $('#migration-started-message').hide();
        }
    });
}, 5000);

function fmt_migration_status(status) {
    if (status === 'in_progress') {
        return '<span class="status-blue">In Progress</span>';
    } else if (status === 'completed') {
        return '<span class="status-green">Completed</span>';
    } else if (status === 'interrupted') {
        return '<span class="status-yellow">Interrupted</span>';
    } else if (status === 'failed') {
        return '<span class="status-red">Failed</span>';
    } else {
        return '<span>' + status + '</span>';
    }
}

function fmt_system_status(status) {
    if (status === 'in_progress') {
        return 'In Progress';
    } else if (status === 'not_running') {
        return 'Idle';
    } else {
        return status;
    }
}

function fmt_queue_status(status) {
    if (status === 'pending') {
        return '<span class="status-yellow">Pending</span>';
    } else if (status === 'in_progress') {
        return '<span class="status-blue">In Progress</span>';
    } else if (status === 'completed') {
        return '<span class="status-green">Completed</span>';
    } else if (status === 'failed') {
        return '<span class="status-red">Failed</span>';
    } else if (status === 'skipped') {
        return '<span class="status-yellow">Skipped</span>';
    } else {
        return '<span>' + status + '</span>';
    }
}

function fmt_progress_bar(completed, total) {
    if (total === 0) return '<div class="progress-bar"><div class="progress" style="width: 0%"></div></div> 0%';

    var percent = Math.round((completed / total) * 100);
    return '<div class="progress-bar"><div class="progress" style="width: ' + percent + '%"></div></div> ' + percent + '%';
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

// Custom sort function for migration tables that defaults to descending order
function fmt_sort_desc_by_default(display, sort) {
    var prefix = '';
    if (current_sort == sort) {
        prefix = '<span class="arrow">' +
            (current_sort_reverse ? '&#9650; ' : '&#9660; ') +
            '</span>';
    }
    return '<a class="sort" sort="' + sort + '">' + prefix + display + '</a>';
}

// Compatibility check formatters

function fmt_check_type_name(checkType) {
    var nameMap = {
        'relaxed_checks_setting': 'Relaxed Checks Setting',
        'leader_balance': 'Queue Leader Balance',
        'queue_synchronization': 'Queue Synchronization',
        'queue_suitability': 'Queue Suitability',
        'message_count': 'Message Count Limits',
        'disk_space': 'Disk Space',
        'snapshot_not_in_progress': 'EBS Snapshot Status'
    };
    return nameMap[checkType] || checkType;
}

function fmt_compatibility_status(compatible) {
    return compatible ?
        '<span class="status-green">Compatible</span>' :
        '<span class="status-red">Unsuitable</span>';
}

function fmt_issue_type(type) {
    var typeMap = {
        'exclusive': 'Exclusive Queue',
        'unsupported_argument': 'Unsupported Argument',
        'max_priority': 'Priority Queue',
        'lazy_mode': 'Lazy Mode',
        'overflow_behavior': 'Overflow Behavior',
        'unsuitable_overflow': 'Unsuitable Overflow',
        'too_many_queues': 'Too Many Queues'
    };
    return typeMap[type] || type;
}

function fmt_system_check_status(status) {
    return status === 'passed' ?
        '<span class="status-green">✓ Passed</span>' :
        '<span class="status-red">✗ Failed</span>';
}

function toggle_issue_details(queueName) {
    $('#issues-' + queueName).toggle();
}

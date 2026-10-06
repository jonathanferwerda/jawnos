$(document).on('keyup', '#terminal_console', function(e) {
	var timestamp = Date.now();
	var event = e;
	var command = $('#terminal_console').val();
 	if (e.keyCode == 13) {
		$('#terminal_view').append('<span style="color:green"><b>' + my_name + ':</b></span> ' + command + '<br>');

		$('#terminal_console').val('');
/*
		$.ajax({
			url: '/manager/terminal',
			type: 'POST',
			data: { timestamp: timestamp, command: command },
			success: function(response) {
			}
		});
*/
		ws['server'].send(JSON.stringify({ 'app': 'server', 'pty': 'yes', keyCode: e.keyCode, command: command }));

	}
	else {

	}
});

$(document).on('keydown', '#terminal_interactive', function(e) {
	var timestamp = Date.now();
	var event = e;
	console.log(e);
	if (!e.metaKey) {
	 	if (e.ctrlKey && !e.altKey && !e.shiftKey) {
			const key = e.key.toUpperCase(); // Force uppercase to align with standard ASCII codes

			// Verify the pressed key is a valid letter between A and Z
			if (key >= 'A' && key <= 'Z') {
				  e.preventDefault(); // Stop default browser macros (like Ctrl+D bookmarking, Ctrl+P printing)

				  // Convert letter code directly to its low ASCII control byte equivalent
				  // 'A' (65) - 64 = 1, 'B' (66) - 64 = 2, 'D' (68) - 64 = 4, etc.
				  const controlByteValue = key.charCodeAt(0) - 64;
				  const controlCharacter = String.fromCharCode(controlByteValue);

				  ws['server'].send(JSON.stringify({ 
				      'app': 'server', 
				      'pty': 'yes', 
				      'type': 'input',
				      'input': controlCharacter 
				  }));
				  
				  return false;
			}
		}
		else {
			var data = { 'app': 'server', 'pty': 'yes', 'type': 'input', input: e.key };
			console.log(data);
			ws['server'].send(JSON.stringify(data));
		}
	}
});

var terminalVars = {
	cursorX: 0,
	cursorY: 0,
  fg: '',   // Stores active foreground class (e.g., 'ansi-32')
  bg: '',   // Stores active background class (e.g., 'ansi-44')
  bold: false,
	COLS: 80,
	ROWS: 24,
	history: [],
	scrollOffset: 0,
  screen: null
};

function createEmptyRow() {
  return Array.from({ length: terminalVars['COLS'] }, () => ({ char: ' ', classes: [] }));
}

function terminalDataReceiver(rData) {
    const terminal = document.getElementById('terminal_interactive');
    if (!terminalVars.screen) {
        terminalVars.screen = Array.from({ length: terminalVars['ROWS'] }, () => createEmptyRow());
    }
    let base64String = rData['terminal']; 
    let binaryString = atob(base64String);



    let bytes = new Uint8Array(binaryString.length);
    for (let i = 0; i < binaryString.length; i++) {
        bytes[i] = binaryString.charCodeAt(i);
    }
    let decoder = new TextDecoder('utf-8');
    let data = decoder.decode(bytes);

    data = data.replace(/\r\n/g, '\n').replace(/\r/g, '\n');


		const grid = document.getElementById('terminal_interactive');

		for (let y = 0; y < terminalVars['ROWS']; y++) {
			let rowEl = document.getElementById(`terminalrow-${y}`);
			if (!rowEl) {
				rowEl = document.createElement('div');
				rowEl.className = 'term-row';
				rowEl.id = `terminalrow-${y}`;
				for (let x = 0; x < terminalVars['COLS']; x++) {
					const cellEl = document.createElement('span');
					cellEl.className = 'term-cell';
					cellEl.id = `terminalcol-${y}-${x}`;
					cellEl.textContent = ' '; // Empty character spaces
					rowEl.appendChild(cellEl);
				}
				grid.appendChild(rowEl);
			}
		}



    const tokenRegex = /(\x1b\[\??[0-9;]*[a-zA-Z]|\x1b\([a-zA-Z0-9]|\x1b\)[a-zA-Z0-9]|\x1b\].*?[\x07]|\x1b\\)|([^\x1b]+)/g;
    let match;

    while ((match = tokenRegex.exec(data)) !== null) {
        if (match[1]) {
            const seq = match[1];
            if (seq.includes('?')) continue; 
            
            if (seq.endsWith('m')) {
                const numbers = seq.match(/\d+/g);
                if (!numbers || numbers.includes('0')) {
                    terminalVars.fg = ''; terminalVars.bg = ''; terminalVars.bold = false;
                    continue;
                }
                numbers.forEach(numStr => {
                    const num = parseInt(numStr);
                    if (num === 1) terminalVars.bold = true;
                    else if (num >= 30 && num <= 37) terminalVars.fg = `ansi-${num}`;
                    else if (num >= 40 && num <= 47) terminalVars.bg = `ansi-${num}`;
                    else if (num === 39) terminalVars.fg = ''; 
                    else if (num === 49) terminalVars.bg = ''; 
                });
            }
            
            if (seq.endsWith('J') && seq.includes('2')) {
                // Clear screen matrix
                terminalVars.screen = Array.from({ length: terminalVars['ROWS'] }, () => createEmptyRow());
                terminalVars['cursorX'] = 0; terminalVars['cursorY'] = 0;
            }
            else if (seq.endsWith('H') || seq.endsWith('f')) {
                const parts = seq.match(/\d+/g);
                if (parts && parts.length === 2) {
                    terminalVars['cursorY'] = Math.min(parseInt(parts[0]) - 1, terminalVars['ROWS'] - 1);
                    terminalVars['cursorX'] = Math.min(parseInt(parts[1]) - 1, terminalVars['COLS'] - 1);
                }
            }
        } 
        else if (match[2]) {
            const textToPrint = match[2];
            for (let i = 0; i < textToPrint.length; i++) {
                const char = textToPrint[i];
                
                if (char === '\n') {
                    if (terminalVars['cursorY'] >= terminalVars['ROWS'] - 1) {
                        // --- SCROLLING VIA VIRTUAL MATRIX ---
                        // 1. Shift the actual memory structure out of the screen array
                        const shiftedRowData = terminalVars.screen.shift();
                        
                        // 2. Format it into your expected history tracking shape
                        const historyRow = { text: [], classes: [] };
                        shiftedRowData.forEach(cellObj => {
                            historyRow.text.push(cellObj.char);
                            historyRow.classes.push(cellObj.classes);
                        });

												if (terminalVars['scrollOffset'] > 0) {
														terminalVars['scrollOffset']++;
												}
                        terminalVars['history'].push(historyRow);

                        if (terminalVars['history'].length > 1000) {
                            terminalVars['history'].shift();
                        }

                        // 3. Push a brand new clean line to the bottom of our memory array

                        terminalVars.screen.push(createEmptyRow());
                        terminalVars['cursorY']--;
                    }
                    terminalVars['cursorX'] = 0;
                    terminalVars['cursorY'] = Math.min(terminalVars['cursorY'] + 1, terminalVars['ROWS'] - 1);
                } else if (char === '\r') {
                    terminalVars['cursorX'] = 0;
                } else {
                    // Update matrix in memory
                    const currentLine = terminalVars.screen[terminalVars['cursorY']];
                    if (currentLine && currentLine[terminalVars['cursorX']]) {
                        const cellData = currentLine[terminalVars['cursorX']];
                        cellData.char = char;
                        
                        // Track ANSI styles
                        const activeClasses = [];
                        if (terminalVars.fg) activeClasses.push(terminalVars.fg);
                        if (terminalVars.bg) activeClasses.push(terminalVars.bg);
                        if (terminalVars.bold) activeClasses.push('ansi-bold');
                        cellData.classes = activeClasses;
                    }
                
                    terminalVars['cursorX']++;
                    if (terminalVars['cursorX'] >= terminalVars['COLS']) {
                        terminalVars['cursorX'] = 0;
                        terminalVars['cursorY'] = Math.min(terminalVars['cursorY'] + 1, terminalVars['ROWS'] - 1);
                    }
                }
            }
            if (textToPrint.match('password')) {
                $('#terminal_console').attr('type', 'password');
            } else {
                $('#terminal_console').attr('type', 'text');
            }
        }
    }

    renderTerminalScreen();
}

function renderTerminalScreen() {
    const offset = terminalVars['scrollOffset'];
    const totalHistory = terminalVars['history'].length;
    const totalRows = terminalVars['ROWS'];

    // Create a unified timeline array for rendering
    // This stacks your historical lines on top, and appends the live screen lines at the bottom
    const visualTimeline = [];

    // 1. Push all history lines
    for (let i = 0; i < totalHistory; i++) {
        visualTimeline.push(terminalVars['history'][i]);
    }

    // 2. Push all live screen lines (convert them to the history format on the fly)
    for (let y = 0; y < totalRows; y++) {
        const matrixRow = terminalVars.screen[y];
        const formattedRow = { text: [], classes: [] };
        
        for (let x = 0; x < terminalVars['COLS']; x++) {
            if (matrixRow && matrixRow[x]) {
                formattedRow.text.push(matrixRow[x].char);
                formattedRow.classes.push(matrixRow[x].classes);
            } else {
                formattedRow.text.push(' ');
                formattedRow.classes.push([]);
            }
        }
        visualTimeline.push(formattedRow);
    }

    // 3. Render the screen rows based on our offset window
    // When offset is 0, we look at the very end of the timeline (the live view)
    // As offset grows, we slide our viewing window up line-by-line smoothly
    for (let screenY = 0; screenY < totalRows; screenY++) {
        const rowEl = document.getElementById(`terminalrow-${screenY}`);
        if (!rowEl) continue;

        // Calculate the exact line index in our unified timeline
        const timelineIndex = (visualTimeline.length - offset) - (totalRows - screenY);
        const cells = rowEl.getElementsByClassName('term-cell');

        if (timelineIndex >= 0 && timelineIndex < visualTimeline.length) {
            const rowData = visualTimeline[timelineIndex];
            
            for (let x = 0; x < cells.length; x++) {
                const cell = cells[x];
                cell.textContent = rowData.text[x] || ' ';
                cell.className = 'term-cell';
                if (rowData.classes[x]) {
                    rowData.classes[x].forEach(cls => cell.classList.add(cls));
                }
            }
        } else {
            // Out of bounds fallback (renders empty space if scrolled past top of history)
            for (let x = 0; x < cells.length; x++) {
                cells[x].textContent = ' ';
                cells[x].className = 'term-cell';
            }
        }
    }
}




function clearScreenGrid(data) {
	if (!data) { data = {}; }
	var columns;
	if (!data['columns']) { columns = []; } else { columns = data['columns']; }
	var rows;
	if (!data['rows']) { rows = []; } else { rows = data['rows']; }
	if (columns.length == 0) {
		columns = Array.from({ length: terminalVars['COLS'] }, (_, index) => index );
	}
	if (rows.length == 0) {
		rows = Array.from({ length: terminalVars['ROWS'] }, (_, index) => index );
	}
	$.each(rows, function(i,y) {
		$.each(columns, function(ii,x) {		
      const cell = document.getElementById(`terminalcol-${y}-${x}`);
			Array.from(cell.classList).forEach(className => {
				if (className !== 'term-cell') {
					cell.classList.remove(className);
				}
			});
      if (cell) cell.textContent = ' ';
    });
  });
	terminalVars['history'] = [];
}

function resizeTerminalGrid(newCols, newRows) {
  terminalVars['COLS'] = newCols;
  terminalVars['ROWS'] = newRows;
  console.log('resizing ' + newRows + ' ' + newCols);
  const grid = document.getElementById('terminal_interactive');
	if (grid) {
	  grid.innerHTML = ''; // Wipe out old row structures cleanly

	  // Re-build target coordinate spans matching new sizing layout limits
	  for (let y = 0; y < terminalVars['ROWS']; y++) {
	      const rowEl = document.createElement('div');
	      rowEl.className = 'term-row';
	      rowEl.id = `terminalrow-${y}`;
	      
	      for (let x = 0; x < terminalVars['COLS']; x++) {
	          const cellEl = document.createElement('span');
	          cellEl.className = 'term-cell';
	          cellEl.id = `terminalcol-${y}-${x}`;
	          cellEl.textContent = ' ';
	          rowEl.appendChild(cellEl);
	      }
	      grid.appendChild(rowEl);
	  }

	  // Keep cursor pointers within safe bounds after sizing down
	  if (terminalVars['cursorX'] >= terminalVars['COLS']) terminalVars['cursorX'] = terminalVars['COLS'] - 1;
	  if (terminalVars['cursorY'] >= terminalVars['ROWS']) terminalVars['cursorY'] = terminalVars['ROWS'] - 1;

	  // Send structural JSON configuration payload back to Perl
	  const resizePayload = {
	      type: 'terminal_resize',
	      cols: terminalVars['COLS'],
	      rows: terminalVars['ROWS']
	  };
	  ws['server'].send(JSON.stringify(resizePayload));
		if (terminalVars['screen']) {
			renderTerminalScreen();
		}
	}
}


function getCharacterDimensions() {
  const dummy = document.createElement('span');
  dummy.style.fontFamily = "'Courier New', Courier, monospace";
  dummy.style.fontSize = "16px";
  dummy.style.lineHeight = "20px";
  dummy.style.position = "absolute";
  dummy.style.visibility = "hidden";
  dummy.textContent = "M";
  document.body.appendChild(dummy);
  
  const rect = dummy.getBoundingClientRect();
  const width = rect.width;
  const height = rect.height; // Should match your 20px line-height
  console.log(width + ' '  + height);
  document.body.removeChild(dummy);
  return { charWidth: width, charHeight: height };
}


const resizeObserver = new ResizeObserver(entries => {
	console.log('resize observer');
  for (let entry of entries) {
      // Get the inner pixel bounds of the containing div (minus padding/borders)
      const { width, height } = entry.contentRect;
      
      const { charWidth, charHeight } = getCharacterDimensions();
      terminalVars['cellWidth'] = charWidth;
			terminalVars['cellHeight'] = charHeight;
      // Calculate the maximum grid capacity
      const calculatedCols = Math.floor(width / charWidth);
      const calculatedRows = Math.floor(height / charHeight);
      
      // Prevent division-by-zero crashes if the container shrinks out of view
      if (calculatedCols > 0 && calculatedRows > 0) {
          // Only fire a resize command if the character grid dimensions actually changed
          if (calculatedCols !== terminalVars['COLS'] || calculatedRows !== terminalVars['ROWS']) {
              resizeTerminalGrid(calculatedCols, calculatedRows);
          }
      }
  }
});


$(document).on('click', '.terminal_view_select', function() {
	var selection = $(this).attr('view');
	$('.terminal_view').hide();
	$('.terminal_view_select').removeAttr('selected');
	$('.terminal_view_select[view="' + selection + '"]').attr('selected', true);
	$('.terminal_view[view="' + selection + '"]').show();
	settingSetter({ 'app': 'terminal', 'setting': 'view', 'value': selection });
	setTimeout(function() {
		terminalOpener({'window_maker': 'no'});
	},300);
	resizeObserver.observe(document.getElementById('terminal_interactive'));
});

$(document).on('click', '.terminal_clear', function() {
	var view = $('#terminal').find('.terminal_view:visible').attr('view');
	settingDeleter({ 'app': 'terminal', 'setting': view });
	$('.terminal_' + view).remove();
});

function terminalOpener(data) {
	var timestamp = Date.now();
	var url = '/manager/terminal';
	var oti = document.getElementById('terminal_interactive')
	if ($('#terminal_toolbox').length > 0) {
		var tid = $('#terminal_toolbox').closest('.wind').attr('id');
		$('#' + tid).show();
		topLevelNow($('#' + tid));
	}
	else {
		$.ajax({
			url: url,
			type: 'GET',
			data: { window_maker: data['window_maker'], timestamp: timestamp },
			success: function(response) {
				if (data['window_maker'] == 'yes') {
					var window_id = windowMaker(response);
				}
				else {
					$('#terminal').replaceWith(response);
				}
				var tv = $('#terminal_input');
				var ti = document.getElementById('terminal_interactive');
				if (!oti) {
					resizeObserver.observe(document.getElementById('terminal'));
					ti.addEventListener('resize', () => {
						const calculatedCols = Math.floor(ti.innerWidth / 10); 
						const calculatedRows = Math.floor(ti.innerHeight / 20);
				  	resizeTerminalGrid(calculatedCols, calculatedRows);
					});
					ti.addEventListener('mousewheel', (e) => {
						console.log(e);
							if (e.deltaY < 0) {
									// Scrolling UP - Go back in history
									terminalVars['scrollOffset'] = Math.min(terminalVars['scrollOffset'] + 3, terminalVars['history'].length);
							} else {
									// Scrolling DOWN - Return to live stream
									terminalVars['scrollOffset'] = Math.max(terminalVars['scrollOffset'] - 3, 0);
							}

							renderTerminalScreen();
							e.preventDefault(); // Stop the outer browser window from scrolling
					});
				}
				$('#terminal_interactive').trigger('resize');
				tv.focus();
			}
		});
	}
}

$(document).on('click', '#terminal_configure_toggle', function() {
	var tc = $('#terminal_configure');
	if (tc.is(':visible')) {
		tc.hide();
	}
	else {
		tc.show();
	}
});




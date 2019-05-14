function gen_error_cell_html(cell) {

	var line_text = cell.getValue();
	var row_data = cell.getRow().getData();

	var cell_html = line_text.substring(0, row_data["span_start"]) +  "<span style='background-color: pink;'>" + line_text.substring(row_data["span_start"], row_data["span_end"]) + "</span>" + line_text.substring(row_data["span_end"]);

	return cell_html;
}


function gen_matches_table(element_id, data_url) {

	var table = new Tabulator("#" + element_id, {
	    height:"300px",
	    layout:"fitColumns",
	    placeholder:"No Data Set",
	    columns:[
		{title:"Build number", field:"build_number", formatter: "link", width: 75, formatterParams: {urlPrefix: "https://circleci.com/gh/pytorch/pytorch/"}},
		{title:"Branch", field:"branch", sorter:"string", widthGrow: 2},
		{title:"Job", field:"job_name", sorter:"string", widthGrow: 3},
		{title:"Build step", field:"build_step", sorter:"string", widthGrow: 2},
		{title:"Line", field:"line_number", width: 100, formatter: function(cell, formatterParams, onRendered) {
			return (cell.getValue() + 1) + " / " + cell.getRow().getData()["line_count"];
		  }},
		{title:"Line text", field:"line_text", sorter:"string", widthGrow: 8, formatter: function(cell, formatterParams, onRendered) {
			return gen_error_cell_html(cell);
		  },
			cellClick: function(e, cell){
			    $("#error-display").html(gen_error_cell_html(cell));
		    },
	        },
	    ],
            ajaxURL: data_url,
	});
}


function gen_all_matches_table(pattern_id) {
	gen_matches_table("all-pattern-matches-table", "/api/pattern-matches?pattern_id=" + pattern_id);
}


function gen_best_matches_table(pattern_id) {
	gen_matches_table("best-pattern-matches-table", "/api/best-pattern-matches?pattern_id=" + pattern_id);
}


function main() {

	var urlParams = new URLSearchParams(window.location.search);
	var pattern_id = urlParams.get('pattern_id');

        gen_patterns_table(pattern_id, []);

        gen_best_matches_table(pattern_id);
        gen_all_matches_table(pattern_id);

}

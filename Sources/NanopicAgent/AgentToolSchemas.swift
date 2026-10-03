// エージェント（MCP）向けツールの説明と引数の形。ツールの処理は AgentTools.swift。
// 辞書のリテラルで書くとコードが大きくなり、最適化にも時間がかかるので、JSON の文字列で持つ。

let coreToolSchemas = ##"""
{
  "add_deformer": {
    "description": "レイヤーかフォルダーにデフォーマを付ける。rotation は移動・回転（中心を軸に回し、移動量だけずらす）、warp は範囲を格子に分けて点をずらす。フォルダーに付けると中のレイヤー全部に効き、内側から外側の順にかかる。範囲と中心は省くと描かれている所から決める。",
    "inputSchema": {
      "properties": {
        "cols": {
          "description": "ワープの格子の横のマス数（既定 4）",
          "type": "integer"
        },
        "kind": {
          "enum": [
            "rotation",
            "warp"
          ],
          "type": "string"
        },
        "layer_id": {
          "type": "string"
        },
        "name": {
          "type": "string"
        },
        "pivot": {
          "description": "回転の中心 [x, y]",
          "items": {
            "type": "number"
          },
          "type": "array"
        },
        "rect": {
          "description": "ワープの範囲 {x, y, width, height}",
          "type": "object"
        },
        "rows": {
          "description": "縦のマス数（既定 4）",
          "type": "integer"
        }
      },
      "required": [
        "layer_id",
        "kind"
      ],
      "type": "object"
    }
  },
  "add_layer": {
    "description": "新しいレイヤー（folder: true ならフォルダー）を編集中のレイヤーの上に作り、編集中にする。below / above に ID を渡すとそのレイヤーの下・上に置く。",
    "inputSchema": {
      "properties": {
        "above": {
          "description": "このレイヤーのすぐ上に置く",
          "type": "string"
        },
        "below": {
          "description": "このレイヤーのすぐ下に置く",
          "type": "string"
        },
        "folder": {
          "type": "boolean"
        },
        "name": {
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "add_parameter": {
    "description": "パラメータ（名前つきのつまみ。例: 首の向き -1〜1、まばたき 0〜1）を足す。範囲を省くと -1〜1、既定値 0。形は set_form で、つまみのいくつかの値ごとに決める。",
    "inputSchema": {
      "properties": {
        "default": {
          "description": "既定値（省くと 0）",
          "type": "number"
        },
        "max": {
          "type": "number"
        },
        "min": {
          "type": "number"
        },
        "name": {
          "type": "string"
        }
      },
      "required": [
        "name"
      ],
      "type": "object"
    }
  },
  "adjust_color": {
    "description": "色調補正: レイヤー（選択範囲があればその中）の色相・彩度・明度、明るさ・コントラストを変える。",
    "inputSchema": {
      "properties": {
        "brightness": {
          "description": "明るさ -100〜100",
          "type": "number"
        },
        "contrast": {
          "description": "コントラスト -100〜100",
          "type": "number"
        },
        "hue": {
          "description": "色相 -180〜180（度）",
          "type": "number"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "lightness": {
          "description": "明度 -100〜100",
          "type": "number"
        },
        "saturation": {
          "description": "彩度 -100〜100",
          "type": "number"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "batch": {
    "description": "複数のツールを順に呼ぶ（1 回のやりとりで済む）。たとえば線をたくさん描く、いくつかの点を塗りつぶすなど。画像を返すツールの画像もそのまま返す。失敗したらそこで止める。",
    "inputSchema": {
      "properties": {
        "calls": {
          "description": "[{\"tool\": 名前, \"arguments\": {...}}, ...]",
          "items": {
            "properties": {
              "arguments": {
                "type": "object"
              },
              "tool": {
                "type": "string"
              }
            },
            "required": [
              "tool"
            ],
            "type": "object"
          },
          "type": "array"
        }
      },
      "required": [
        "calls"
      ],
      "type": "object"
    }
  },
  "clear": {
    "description": "選択範囲の中（なければレイヤー全体）を消去する。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "close_gaps": {
    "description": "find_gaps の候補を閉じ線として描く。閉じ線のレイヤー（なければ「閉じ線」を線画の上に作る）に描いて非表示にする。そのあと find_regions の reference に [線画, 閉じ線] を渡す。",
    "inputSchema": {
      "properties": {
        "gaps": {
          "description": "閉じる番号の配列、または \"all\""
        },
        "layer_id": {
          "description": "閉じ線のレイヤー。省略すると「閉じ線」レイヤー",
          "type": "string"
        },
        "width": {
          "description": "線の太さ px（既定 3）",
          "type": "number"
        }
      },
      "required": [
        "gaps"
      ],
      "type": "object"
    }
  },
  "create_brush": {
    "description": "既存のブラシを元に新しいブラシを作る（ユーザーのブラシ一覧に加わる）。",
    "inputSchema": {
      "properties": {
        "from": {
          "description": "元にするブラシの名前か ID",
          "type": "string"
        },
        "name": {
          "type": "string"
        },
        "settings": {
          "description": "変える項目",
          "type": "object"
        }
      },
      "required": [
        "from",
        "name"
      ],
      "type": "object"
    }
  },
  "crop": {
    "description": "キャンバスを切り詰める（全レイヤー）。rect を渡すとその範囲、省略すると選択範囲を囲む矩形。",
    "inputSchema": {
      "properties": {
        "rect": {
          "properties": {
            "height": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            }
          },
          "type": "object"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "delete_layer": {
    "description": "レイヤーを削除する。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "type": "string"
        }
      },
      "required": [
        "layer_id"
      ],
      "type": "object"
    }
  },
  "duplicate_layer": {
    "description": "レイヤーを複製する。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "edit_palette": {
    "description": "パレット（登録した色）に色を足す・消す。今のパレットは get_document の palette。",
    "inputSchema": {
      "properties": {
        "add": {
          "description": "足す色 \"#RRGGBB\" の配列（同じ色があれば足さない）",
          "items": {
            "type": "string"
          },
          "type": "array"
        },
        "remove": {
          "description": "消す色 \"#RRGGBB\" の配列",
          "items": {
            "type": "string"
          },
          "type": "array"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "fill": {
    "description": "塗りつぶし（バケツ）。点 (x, y) から色の近い範囲を塗る。",
    "inputSchema": {
      "properties": {
        "color": {
          "description": "\"#RRGGBB\"。省略すると現在の描画色",
          "type": "string"
        },
        "expand": {
          "type": "integer"
        },
        "gap_close": {
          "type": "integer"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "reference": {
          "description": "\"all\"（既定）、\"layer\"（塗るレイヤーだけ）、\"reference_layers\"",
          "type": "string"
        },
        "tolerance": {
          "description": "色の許容誤差 0〜1（既定はアプリの設定）",
          "type": "number"
        },
        "x": {
          "type": "number"
        },
        "y": {
          "type": "number"
        }
      },
      "required": [
        "x",
        "y"
      ],
      "type": "object"
    }
  },
  "fill_leftovers": {
    "description": "下塗りの塗り残し（線画で囲まれた、まだ塗っていない小さなすき間）を探し、接している色で塗る。fill_regions や lasso_fill のあとの仕上げに。",
    "inputSchema": {
      "properties": {
        "expand": {
          "description": "線の下へ広げる px（既定 2）",
          "type": "integer"
        },
        "layer_id": {
          "description": "下塗りのレイヤー、またはパーツごとのレイヤーを入れたフォルダー。省略すると編集中のレイヤー",
          "type": "string"
        },
        "line_threshold": {
          "type": "number"
        },
        "max_area": {
          "description": "これより大きいすき間は塗らない（px、既定 400）",
          "type": "integer"
        },
        "reference": {
          "description": "線画のレイヤー ID か ID の配列。省略すると直前の find_regions と同じ"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "fill_regions": {
    "description": "find_regions の番号の範囲を色で塗る。複数をまとめて渡せる（取り消しは 1 回分）。線の下まで expand px 広げて塗るが、隣の範囲にははみ出さない。",
    "inputSchema": {
      "properties": {
        "expand": {
          "description": "線の下へ広げる px（既定 2）",
          "type": "integer"
        },
        "fills": {
          "description": "[{\"region\": 番号, \"color\": \"#RRGGBB\", \"name\": \"髪\"}, ...]。name はパーツ名（separate_layers のときのレイヤー名）",
          "items": {
            "properties": {
              "color": {
                "type": "string"
              },
              "name": {
                "type": "string"
              },
              "region": {
                "type": "integer"
              }
            },
            "required": [
              "region",
              "color"
            ],
            "type": "object"
          },
          "type": "array"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "separate_layers": {
          "description": "name（なければ色）ごとにレイヤーを分けて塗る。レイヤーはフォルダーにまとめ、線画の下に作る（同じ name のレイヤーがあればそこに足す）",
          "type": "boolean"
        }
      },
      "required": [
        "fills"
      ],
      "type": "object"
    }
  },
  "fill_selection": {
    "description": "選択範囲（なければレイヤー全体）を色で塗る。select で楕円や多角形を選んでから塗る、などに。",
    "inputSchema": {
      "properties": {
        "color": {
          "description": "\"#RRGGBB\"。省略すると現在の描画色",
          "type": "string"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "find_gaps": {
    "description": "線画の開いた所（線の端が近くの線に届いていない所）を探し、閉じる線分の候補を番号つきで返す（画像に赤い線で描く）。close_gaps でまとめて閉じ線にできる。find_regions で範囲が隣や背景とつながってしまうときに。",
    "inputSchema": {
      "properties": {
        "line_threshold": {
          "type": "number"
        },
        "max_distance": {
          "description": "これより長い隙間は探さない（px、既定 40）",
          "type": "integer"
        },
        "max_size": {
          "description": "画像の長辺の最大 px（既定 1024）",
          "type": "integer"
        },
        "reference": {
          "description": "線画のレイヤー ID か ID の配列。省略すると直前の find_regions と同じ"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "find_regions": {
    "description": "線画で囲まれた範囲を探して番号をつける（下塗り用）。番号・面積・範囲・内側の点・今の色を一覧で、番号を描き込んだ画像と一緒に返す。結果は fill_regions と select で使える。",
    "inputSchema": {
      "properties": {
        "gap_close": {
          "description": "この px までの線の途切れを閉じて扱う（既定 0）",
          "type": "integer"
        },
        "line_threshold": {
          "description": "白背景に重ねた暗さがこれ以上を線とみなす 0〜1（既定 0.5）",
          "type": "number"
        },
        "list_min_area": {
          "description": "これより小さい範囲は一覧に載せず数だけ返す（px、既定 150）",
          "type": "integer"
        },
        "reference": {
          "description": "線として見るもの: 線画のレイヤー ID か ID の配列（線画＋閉じ線のレイヤーなど。非表示でもよい）、\"all\"（見えている全体、既定）、\"reference_layers\"（参照レイヤー）"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "get_document": {
    "description": "ドキュメントの大きさ、レイヤーの一覧（上から順、ID・名前・合成モード・不透明度・描かれている範囲など）、編集中のレイヤー、選択範囲、描画色、選択中のブラシを返す。",
    "inputSchema": {
      "properties": {},
      "required": [],
      "type": "object"
    }
  },
  "get_image": {
    "description": "キャンバスの見た目を PNG で返す。layer_id を渡すとそのレイヤーだけ（白背景）。region で一部を拡大して見られる。grid: true で座標の目盛りを重ねる。",
    "inputSchema": {
      "properties": {
        "grid": {
          "description": "座標の目盛りを重ねる",
          "type": "boolean"
        },
        "layer_id": {
          "description": "このレイヤーだけを描く",
          "type": "string"
        },
        "max_size": {
          "description": "画像の長辺の最大 px（既定 1024）",
          "type": "integer"
        },
        "region": {
          "description": "見る範囲（ドキュメント座標）。省略すると全体",
          "properties": {
            "height": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            }
          },
          "type": "object"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "group_layers": {
    "description": "いくつかのレイヤーを新しいフォルダーにまとめる。",
    "inputSchema": {
      "properties": {
        "layer_ids": {
          "items": {
            "type": "string"
          },
          "type": "array"
        },
        "name": {
          "type": "string"
        }
      },
      "required": [
        "layer_ids"
      ],
      "type": "object"
    }
  },
  "lasso_fill": {
    "description": "点を結んだ多角形の内側を塗る（erase: true なら消す）。",
    "inputSchema": {
      "properties": {
        "antialias": {
          "description": "既定 true",
          "type": "boolean"
        },
        "color": {
          "description": "\"#RRGGBB\"。省略すると現在の描画色",
          "type": "string"
        },
        "erase": {
          "type": "boolean"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "points": {
          "description": "[[x, y], ...]",
          "items": {
            "items": {
              "type": "number"
            },
            "type": "array"
          },
          "type": "array"
        }
      },
      "required": [
        "points"
      ],
      "type": "object"
    }
  },
  "list_brushes": {
    "description": "ブラシと消しゴムの一覧（ID・名前・大きさ）。detail: true ですべての設定項目も返す。",
    "inputSchema": {
      "properties": {
        "detail": {
          "type": "boolean"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "merge_down": {
    "description": "レイヤーを下のレイヤーに結合する。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "move_layer": {
    "description": "レイヤーを target の上（above）・下（below）・フォルダーの中（into）へ動かす。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "type": "string"
        },
        "placement": {
          "enum": [
            "above",
            "below",
            "into"
          ],
          "type": "string"
        },
        "target": {
          "type": "string"
        }
      },
      "required": [
        "layer_id",
        "target",
        "placement"
      ],
      "type": "object"
    }
  },
  "pick_color": {
    "description": "点の色を返す（layer_only: true なら編集中のレイヤーだけを見る）。",
    "inputSchema": {
      "properties": {
        "layer_only": {
          "type": "boolean"
        },
        "x": {
          "type": "integer"
        },
        "y": {
          "type": "integer"
        }
      },
      "required": [
        "x",
        "y"
      ],
      "type": "object"
    }
  },
  "publish": {
    "description": "書き出しの設定どおりに、今見えている状態（表示中のレイヤー、今のコマ）を書き出し先に書き出す（上書き）。",
    "inputSchema": {
      "properties": {
        "destination": {
          "description": "書き出し先を変えるとき、そのパス（設定にも残る）",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "publish_settings": {
    "description": "書き出し（publish）の設定を見る・変える。作品ごとに 1 組あり、サイドカーに保存される。範囲を切り抜き、出力の大きさに変えて書き出す（元の絵は変えない）。範囲の縦横比は出力の比に合わせる。引数を省くと今の設定を返すだけ。",
    "inputSchema": {
      "properties": {
        "background": {
          "description": "透明な所の扱い（JPEG はいつも白）",
          "enum": [
            "transparent",
            "white"
          ],
          "type": "string"
        },
        "destination": {
          "description": "書き出し先のファイルのパス",
          "type": "string"
        },
        "format": {
          "enum": [
            "png",
            "jpeg"
          ],
          "type": "string"
        },
        "output_height": {
          "description": "出力の高さ",
          "type": "integer"
        },
        "output_width": {
          "description": "出力の幅。片方だけなら比を保ってもう一方も変える。両方なら範囲をその比に合わせ直す",
          "type": "integer"
        },
        "quality": {
          "description": "JPEG の品質（1〜100）",
          "type": "integer"
        },
        "rect": {
          "description": "書き出す範囲 {x, y, width, height}（キャンバスの座標）。出力の高さはこの比に合わせる",
          "type": "object"
        },
        "whole_canvas": {
          "description": "範囲をキャンバス全体にする",
          "type": "boolean"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "redo": {
    "description": "やり直す。",
    "inputSchema": {
      "properties": {
        "steps": {
          "type": "integer"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "resize_canvas": {
    "description": "キャンバスの大きさを変える（左上を基準に、絵は拡大縮小しない）。",
    "inputSchema": {
      "properties": {
        "height": {
          "type": "integer"
        },
        "width": {
          "type": "integer"
        }
      },
      "required": [
        "width",
        "height"
      ],
      "type": "object"
    }
  },
  "rig": {
    "description": "デフォーマとパラメータを見る。パラメータの値を動かす（values）と、変形の表示が入ってキャンバスにポーズが出る（get_image で見られる）。変形を表示している間は描けないので、描く前に show_deformation: false。",
    "inputSchema": {
      "properties": {
        "reset_pose": {
          "description": "すべてのつまみを既定値に戻す",
          "type": "boolean"
        },
        "show_deformation": {
          "description": "変形の表示を入り切りする（false なら描いた絵そのままを表示し、描ける）",
          "type": "boolean"
        },
        "values": {
          "description": "{パラメータ ID: 値} でつまみを動かす",
          "type": "object"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "select": {
    "description": "選択範囲を作る。選択範囲があると、塗る・描く・消す操作はその中だけに効く。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "description": "layer で使うレイヤー",
          "type": "string"
        },
        "op": {
          "description": "既定 replace",
          "enum": [
            "replace",
            "add",
            "subtract",
            "intersect"
          ],
          "type": "string"
        },
        "points": {
          "description": "polygon の頂点",
          "items": {
            "items": {
              "type": "number"
            },
            "type": "array"
          },
          "type": "array"
        },
        "rect": {
          "description": "rect / ellipse の範囲",
          "properties": {
            "height": {
              "type": "integer"
            },
            "width": {
              "type": "integer"
            },
            "x": {
              "type": "integer"
            },
            "y": {
              "type": "integer"
            }
          },
          "type": "object"
        },
        "reference": {
          "description": "wand が見るもの: \"all\"（既定）、\"layer\"（編集中のレイヤー）、\"reference_layers\"",
          "type": "string"
        },
        "regions": {
          "description": "find_regions の番号",
          "items": {
            "type": "integer"
          },
          "type": "array"
        },
        "shape": {
          "description": "wand: 点 (x, y) から色の近い範囲（自動選択）。layer: layer_id のレイヤーの描かれている部分",
          "enum": [
            "rect",
            "ellipse",
            "polygon",
            "regions",
            "wand",
            "layer",
            "all",
            "none",
            "invert"
          ],
          "type": "string"
        },
        "tolerance": {
          "description": "wand の色の許容誤差 0〜1",
          "type": "number"
        },
        "x": {
          "type": "integer"
        },
        "y": {
          "type": "integer"
        }
      },
      "required": [
        "shape"
      ],
      "type": "object"
    }
  },
  "select_brush": {
    "description": "ブラシ（または消しゴム）を名前か ID で選ぶ。以後ユーザーが描くときもそのブラシになる。",
    "inputSchema": {
      "properties": {
        "brush": {
          "type": "string"
        }
      },
      "required": [
        "brush"
      ],
      "type": "object"
    }
  },
  "set_active_layer": {
    "description": "編集するレイヤーを選ぶ。",
    "inputSchema": {
      "properties": {
        "layer_id": {
          "type": "string"
        }
      },
      "required": [
        "layer_id"
      ],
      "type": "object"
    }
  },
  "set_color": {
    "description": "描画色（main）とサブカラー（sub）を設定する。",
    "inputSchema": {
      "properties": {
        "main": {
          "description": "\"#RRGGBB\"",
          "type": "string"
        },
        "sub": {
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "set_form": {
    "description": "パラメータが value のときのデフォーマの形を決める（キーがなければ作る）。形は基本の形からのずれ。移動・回転（rotation）は angle（度、時計回り）と move（[dx, dy]、移動量）。ワープは offsets（格子の点ごとの [dx, dy]、左上から右へ行ごと、点の数は (cols+1)*(rows+1)）か、points（{点の番号: [dx, dy]} で一部だけ）。move はワープにも効く（全体をずらす）。値の間は直線で補間される。既定値にキーがなければずれ 0 とみなす。",
    "inputSchema": {
      "properties": {
        "angle": {
          "type": "number"
        },
        "deformer": {
          "type": "string"
        },
        "move": {
          "description": "移動量 [dx, dy]",
          "items": {
            "type": "number"
          },
          "type": "array"
        },
        "offsets": {
          "items": {
            "items": {
              "type": "number"
            },
            "type": "array"
          },
          "type": "array"
        },
        "parameter": {
          "type": "string"
        },
        "points": {
          "type": "object"
        },
        "value": {
          "type": "number"
        }
      },
      "required": [
        "parameter",
        "value",
        "deformer"
      ],
      "type": "object"
    }
  },
  "set_key": {
    "description": "タイムラインにキーを打つ。スイッチフォルダーなら child（表示する子のレイヤー ID）、ふつうのレイヤーなら visible を渡す。トラックがなければ作る。",
    "inputSchema": {
      "properties": {
        "child": {
          "description": "スイッチフォルダーで表示する子のレイヤー ID",
          "type": "string"
        },
        "delete": {
          "description": "そのコマのキーを消す",
          "type": "boolean"
        },
        "easing": {
          "description": "パラメータのキーから次のキーまでの動き方（既定 linear）。easeIn はゆっくり始まる、easeOut はゆっくり止まる、easeInOut は両方、hold は次のキーまで値を保つ",
          "enum": [
            "linear",
            "easeIn",
            "easeOut",
            "easeInOut",
            "hold"
          ],
          "type": "string"
        },
        "frame": {
          "description": "0 から",
          "type": "integer"
        },
        "layer_id": {
          "description": "レイヤーかスイッチフォルダー（パラメータのキーなら省いて parameter を渡す）",
          "type": "string"
        },
        "parameter": {
          "description": "パラメータ ID（値は value。キーの間は直線で補間）",
          "type": "string"
        },
        "value": {
          "type": "number"
        },
        "visible": {
          "description": "レイヤーを表示するか。スイッチフォルダーに false を渡すと空のコマ（そのコマではフォルダーごと出さない）",
          "type": "boolean"
        }
      },
      "required": [
        "frame"
      ],
      "type": "object"
    }
  },
  "stroke": {
    "description": "ブラシで線を描く。点は [x, y] か [x, y, 筆圧 0〜1]。点の間は滑らかにつなぐ。筆圧を渡すとブラシの筆圧設定が効く。",
    "inputSchema": {
      "properties": {
        "brush": {
          "description": "ブラシの名前か ID（list_brushes）。省略すると選択中のブラシ",
          "type": "string"
        },
        "color": {
          "description": "\"#RRGGBB\"（このストロークだけ）。省略すると現在の描画色",
          "type": "string"
        },
        "curve": {
          "description": "点を滑らかな曲線（点を通る曲線）でつなぐ。少ない点で自然な線が引ける",
          "type": "boolean"
        },
        "erase": {
          "description": "消しゴムで描く",
          "type": "boolean"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "opacity": {
          "description": "不透明度 0〜1（このストロークだけ）",
          "type": "number"
        },
        "points": {
          "items": {
            "items": {
              "type": "number"
            },
            "type": "array"
          },
          "type": "array"
        },
        "settings": {
          "description": "ブラシ設定の上書き（このストロークだけ）。項目は list_brushes の detail: true で見られる（hardness, flow, spacing, smoothing など）",
          "type": "object"
        },
        "size": {
          "description": "直径 px（このストロークだけ）",
          "type": "number"
        }
      },
      "required": [
        "points"
      ],
      "type": "object"
    }
  },
  "timeline": {
    "description": "タイムライン（簡易アニメーション）を見る・設定する。レイヤーの表示／非表示と、スイッチフォルダーの子の切り替えをコマごとに切り替える（補間なし）。引数を省くと今の設定とトラックを返すだけ。",
    "inputSchema": {
      "properties": {
        "fps": {
          "type": "integer"
        },
        "frame": {
          "description": "再生位置を動かす（0 から）。そのコマの表示がキャンバスに当たる",
          "type": "integer"
        },
        "frame_count": {
          "description": "長さ（コマ数）",
          "type": "integer"
        },
        "loop": {
          "type": "boolean"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "transform": {
    "description": "選択範囲の中（なければレイヤー全体）を動かす・拡大縮小する・回転する・反転する。中心は対象の範囲の中心。",
    "inputSchema": {
      "properties": {
        "dx": {
          "description": "右へ動かす px",
          "type": "number"
        },
        "dy": {
          "description": "下へ動かす px",
          "type": "number"
        },
        "flip_horizontal": {
          "type": "boolean"
        },
        "flip_vertical": {
          "type": "boolean"
        },
        "layer_id": {
          "description": "対象のレイヤー ID。省略すると編集中のレイヤー",
          "type": "string"
        },
        "rotation": {
          "description": "度。正の値で時計回り",
          "type": "number"
        },
        "scale": {
          "description": "縦横同じ倍率",
          "type": "number"
        },
        "scale_x": {
          "type": "number"
        },
        "scale_y": {
          "type": "number"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "undo": {
    "description": "取り消す。",
    "inputSchema": {
      "properties": {
        "steps": {
          "description": "既定 1",
          "type": "integer"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "update_brush": {
    "description": "ブラシの設定を変えて保存する（ユーザーのブラシも変わる）。一時的に変えたいだけなら stroke の settings を使う。",
    "inputSchema": {
      "properties": {
        "brush": {
          "description": "名前か ID",
          "type": "string"
        },
        "settings": {
          "description": "変える項目（list_brushes の detail: true で見られる名前）",
          "type": "object"
        }
      },
      "required": [
        "brush",
        "settings"
      ],
      "type": "object"
    }
  },
  "update_layer": {
    "description": "レイヤーの設定を変える（指定した項目だけ）。",
    "inputSchema": {
      "properties": {
        "blend_mode": {
          "enum": [
            "passThrough",
            "normal",
            "darken",
            "multiply",
            "colorBurn",
            "linearBurn",
            "subtract",
            "darkerColor",
            "lighten",
            "screen",
            "colorDodge",
            "linearDodge",
            "lighterColor",
            "overlay",
            "softLight",
            "hardLight",
            "vividLight",
            "linearLight",
            "pinLight",
            "hardMix",
            "difference",
            "exclusion",
            "divide",
            "hue",
            "saturation",
            "color",
            "luminosity",
            "dissolve"
          ],
          "type": "string"
        },
        "clipping": {
          "type": "boolean"
        },
        "layer_id": {
          "type": "string"
        },
        "lock_alpha": {
          "description": "透明ピクセルをロック",
          "type": "boolean"
        },
        "locked": {
          "type": "boolean"
        },
        "name": {
          "type": "string"
        },
        "opacity": {
          "description": "0〜1",
          "type": "number"
        },
        "reference": {
          "description": "参照レイヤー",
          "type": "boolean"
        },
        "switch": {
          "description": "フォルダーをスイッチフォルダー（子を常に 1 つだけ表示。表情の差分など）にする。子を表示するには、その子を visible: true にする",
          "type": "boolean"
        },
        "visible": {
          "type": "boolean"
        }
      },
      "required": [
        "layer_id"
      ],
      "type": "object"
    }
  }
}
"""##

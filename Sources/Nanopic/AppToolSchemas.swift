// アプリ側のエージェント向けツールの説明と引数の形。ツールの処理は AgentIntegration.swift

let appToolSchemas = ##"""
{
  "export_movie": {
    "description": "タイムラインを動画に書き出す。範囲・大きさ・透明な所の扱いは書き出しの設定（publish_settings）に合わせる。透明を持てる形式で透明にするには、用紙のレイヤーを隠しておく。",
    "inputSchema": {
      "properties": {
        "format": {
          "description": "mp4: H.264（透明なし、白）、prores: MOV ProRes 4444（透過、動画編集ソフト向け）、apng: アニメーション PNG（透過、Web 向け）、pngSequence: コマごとの PNG（透過）。既定は mp4",
          "enum": [
            "mp4",
            "prores",
            "apng",
            "pngSequence"
          ],
          "type": "string"
        },
        "path": {
          "description": "絶対パス。pngSequence ならフォルダー（なければ作る）",
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "type": "object"
    }
  },
  "export_mp4": {
    "description": "タイムラインを MP4 動画に書き出す（透明な部分は白。長辺は 3840px まで）。",
    "inputSchema": {
      "properties": {
        "path": {
          "description": "絶対パス（.mp4）",
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "type": "object"
    }
  },
  "export_png": {
    "description": "見た目を 1 枚の PNG に書き出す。",
    "inputSchema": {
      "properties": {
        "path": {
          "description": "絶対パス（.png）",
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "type": "object"
    }
  },
  "import_image": {
    "description": "画像ファイルを新しいレイヤーとして読み込む（キャンバスの中央に置く）。",
    "inputSchema": {
      "properties": {
        "path": {
          "description": "絶対パス",
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "type": "object"
    }
  },
  "new_document": {
    "description": "新しいキャンバスを作る（用紙と空のレイヤー 1 枚）。",
    "inputSchema": {
      "properties": {
        "discard_changes": {
          "description": "保存していない変更を捨ててよい（既定 false。変更があると失敗する）",
          "type": "boolean"
        },
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
  "open_file": {
    "description": "PSD や画像ファイルを開く（今のキャンバスは閉じる）。",
    "inputSchema": {
      "properties": {
        "discard_changes": {
          "description": "保存していない変更を捨ててよい（既定 false。変更があると失敗する）",
          "type": "boolean"
        },
        "path": {
          "description": "絶対パス",
          "type": "string"
        }
      },
      "required": [
        "path"
      ],
      "type": "object"
    }
  },
  "save_psd": {
    "description": "PSD で保存する。path を省略すると今のファイルに上書きする。",
    "inputSchema": {
      "properties": {
        "path": {
          "description": "絶対パス（.psd）",
          "type": "string"
        }
      },
      "required": [],
      "type": "object"
    }
  },
  "set_view": {
    "description": "ユーザーの画面の表示を変える（作業している所を見せる）。region を渡すとそこを画面いっぱいに、fit: true で全体を表示。",
    "inputSchema": {
      "properties": {
        "fit": {
          "type": "boolean"
        },
        "region": {
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
  }
}
"""##
